defmodule Reencodarr.Encoder do
  use GenServer
  require Logger

  alias Reencodarr.{Media, AbAv1, Repo}

  @check_interval 5000

  # Public API
  @spec start_link(any()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def get_next_for_encoding, do: GenServer.call(__MODULE__, :get_next_for_encoding)
  def start, do: GenServer.cast(__MODULE__, :start_encoding)
  def pause, do: GenServer.cast(__MODULE__, :pause_encoding)
  # Returns true if encoding is active, false otherwise
  def running? do
    case GenServer.whereis(__MODULE__) do
      nil ->
        false

      pid ->
        GenServer.call(pid, :encoding?)
    end
  end

  # GenServer Callbacks
  @impl true
  def init(state) do
    Logger.info("Initializing Encoder...")
    monitor_encode()
    {:ok, Map.put(state, :encoding, false)}
  end

  @impl true
  def handle_cast(:start_encoding, state) do
    Logger.debug("Encoding started")
    schedule_check()
    {:noreply, %{state | encoding: true}}
  end

  @impl true
  def handle_cast(:pause_encoding, state) do
    Logger.debug("Encoding paused")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "encoder", {:encoder, :paused})
    {:noreply, %{state | encoding: false}}
  end

  @impl true
  def handle_cast(:empty, state) do
    Logger.error("Queue is empty")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:encoding_complete, video, output_file_from_encoder}, state) do
    Logger.info("Encoding completed for video #{video.id} (original path: #{video.path})")

    intermediate_reencoded_path = calculate_intermediate_path(video)

    case move_encoder_output_to_intermediate(
           output_file_from_encoder,
           intermediate_reencoded_path,
           video
         ) do
      {:ok, actual_intermediate_path} ->
        # Reload the video using Repo.reload for simplicity
        case Repo.reload(video) do
          nil ->
            Logger.error("Failed to reload video #{video.id}: Video not found.")

          reloaded_video ->
            case Media.mark_as_reencoded(reloaded_video) do
              {:ok, _updated_video} ->
                # Then, attempt to finalize (rename to original path) and sync
                finalize_and_sync_video(reloaded_video, actual_intermediate_path)

              {:error, reason} ->
                Logger.error("Failed to mark video #{video.id} as re-encoded: #{inspect(reason)}")
            end
        end

      {:error, _reason_already_logged_and_video_marked_failed} ->
        # Error handled and video marked as failed within move_encoder_output_to_intermediate
        # Nothing more to do here, error is logged and video status updated
        :ok
    end

    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "encoder", {:encoder, :none})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:encoding_failed, video, exit_code}, state) do
    Logger.error("Encoding failed for video #{video.id} with exit code #{exit_code}")
    Media.mark_as_failed(video)
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "encoder", {:encoder, :none})
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_next_video, %{encoding: true} = state) do
    check_next_video()
    schedule_check()
    {:noreply, state}
  end

  def handle_info(:check_next_video, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(%{action: "encoding:complete", result: {:error, 143}, video: video}, state) do
    Logger.error("Encoding failed with error code 143 for video #{video.id}")
    {:noreply, state}
  end

  @impl true
  def handle_info(
        %{action: "encoding:complete", result: {:error, exit_code}, video: video},
        state
      )
      when exit_code != 0 do
    Logger.error("Encoding failed with error code #{exit_code} for video #{video.id}")
    Media.mark_as_failed(video)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    Logger.warning("AbAv1.Encode process crashed or is not yet started.")
    Process.send_after(self(), :monitor_encode, 10_000)
    {:noreply, state}
  end

  @impl true
  def handle_info(:monitor_encode, state) do
    monitor_encode()
    {:noreply, state}
  end

  @impl true
  def handle_call(:encoding?, _from, %{encoding: encoding} = state) do
    {:reply, encoding, state}
  end

  @impl true
  def terminate(_reason, _state) do
    System.cmd("pkill", ["-f", "ab-av1"])
    :ok
  end

  # Private Helper Functions

  defp calculate_intermediate_path(video) do
    Path.join(
      Path.dirname(video.path),
      Path.basename(video.path, Path.extname(video.path)) <>
        ".reencoded" <> Path.extname(video.path)
    )
  end

  # Generic helper to handle file rename or copy (for exdev)
  # Returns :ok on success, or {:error, reason} on failure.
  defp rename_or_copy_file(source, destination, log_prefix, video) do
    case File.rename(source, destination) do
      :ok ->
        Logger.info(
          "[#{log_prefix}] Successfully renamed #{source} to #{destination} for video #{video.id}"
        )

        :ok

      {:error, :exdev} ->
        Logger.info(
          "[#{log_prefix}] Cross-device rename for #{source} to #{destination} (video #{video.id}). Attempting copy and delete."
        )

        case File.cp(source, destination) do
          :ok ->
            Logger.info(
              "[#{log_prefix}] Successfully copied #{source} to #{destination} for video #{video.id}"
            )

            case File.rm(source) do
              :ok ->
                Logger.info(
                  "[#{log_prefix}] Successfully removed original file #{source} after copy for video #{video.id}"
                )

              {:error, rm_reason} ->
                Logger.error(
                  "[#{log_prefix}] Failed to remove original file #{source} after copy for video #{video.id}: #{rm_reason}"
                )
            end

            :ok

          {:error, cp_reason} ->
            Logger.error(
              "[#{log_prefix}] Failed to copy #{source} to #{destination} for video #{video.id}: #{cp_reason}. File remains at #{source}."
            )

            {:error, cp_reason}
        end

      {:error, reason} ->
        Logger.error(
          "[#{log_prefix}] Failed to rename #{source} to #{destination} for video #{video.id}: #{reason}. File remains at #{source}."
        )

        {:error, reason}
    end
  end

  # Moves the raw output from the encoder to an intermediate path (e.g., original_name.reencoded.mkv)
  # Marks video as failed if this step fails.
  # Returns {:ok, intermediate_path} or {:error, reason_atom}
  defp move_encoder_output_to_intermediate(
         output_file_from_encoder,
         intermediate_reencoded_path,
         video
       ) do
    log_prefix = "IntermediateMove"

    case rename_or_copy_file(
           output_file_from_encoder,
           intermediate_reencoded_path,
           log_prefix,
           video
         ) do
      :ok ->
        Logger.info(
          "[#{log_prefix}] Encoder output #{output_file_from_encoder} successfully placed at intermediate path #{intermediate_reencoded_path} for video #{video.id}"
        )

        {:ok, intermediate_reencoded_path}

      {:error, _reason} ->
        # rename_or_copy_file already logged the specific error
        Logger.error(
          "[#{log_prefix}] Failed to place encoder output at intermediate path #{intermediate_reencoded_path} for video #{video.id}. Marking as failed."
        )

        Media.mark_as_failed(video)
        {:error, :failed_to_move_to_intermediate}
    end
  end

  # Renames the intermediate file to the final video.path and calls Sync.
  # Calls Sync regardless of the final rename operation's success, as per original logic.
  defp finalize_and_sync_video(video, intermediate_path) do
    log_prefix = "FinalRename"
    # Attempt to rename the intermediate file to the final video.path
    case rename_or_copy_file(intermediate_path, video.path, log_prefix, video) do
      :ok ->
        Logger.info(
          "[#{log_prefix}] Successfully finalized re-encoded file from #{intermediate_path} to #{video.path} for video #{video.id}"
        )

      {:error, _reason} ->
        # rename_or_copy_file already logged the specific error
        Logger.error(
          "[#{log_prefix}] Failed to finalize re-encoded file from #{intermediate_path} to #{video.path} for video #{video.id}. " <>
            "The file may remain at #{intermediate_path}. Sync will still be called."
        )
    end

    # Always call Sync as per original logic for errors/success in this stage
    Logger.info(
      "Calling Sync.refresh_and_rename_from_video for video #{video.id} (path: #{video.path}) after finalization attempt."
    )

    Reencodarr.Sync.refresh_and_rename_from_video(video)
  end

  defp check_next_video do
    with pid when not is_nil(pid) <- GenServer.whereis(Reencodarr.AbAv1.Encode),
         false <- AbAv1.Encode.running?(),
         chosen_vmaf when not is_nil(chosen_vmaf) <- Media.get_next_for_encoding() do
      Logger.debug("Next video to re-encode: #{chosen_vmaf.video.path}")
      AbAv1.encode(chosen_vmaf)
    else
      nil ->
        Logger.error("Encode process is not running.")

      true ->
        Logger.debug("Encoding is already in progress, skipping check for next video.")

      other ->
        Logger.error("No chosen VMAF found for video or some other error: #{inspect(other)}")
    end
  end

  defp schedule_check do
    Process.send_after(self(), :check_next_video, @check_interval)
  end

  defp monitor_encode do
    case GenServer.whereis(Reencodarr.AbAv1.Encode) do
      nil ->
        Logger.error("Encode process is not running.")
        Process.send_after(self(), :monitor_encode, 10_000)

      pid ->
        Process.monitor(pid)
    end
  end
end
