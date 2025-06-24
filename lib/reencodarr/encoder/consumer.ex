defmodule Reencodarr.Encoder.Consumer do
  use GenStage
  require Logger
  alias Reencodarr.{Media, Repo, AbAv1}

  def start_link() do
    GenStage.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    # Subscribe to encoder events
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "encoder")
    {:consumer, %{}, subscribe_to: [{Reencodarr.Encoder.Producer, max_demand: 1}]}
  end

  @impl true
  def handle_events(vmafs, _from, state) do
    for vmaf <- vmafs do
      Task.Supervisor.start_child(Reencodarr.TaskSupervisor, fn ->
        try do
          Logger.info("Starting encoding for #{vmaf.video.path}")
          # AbAv1.encode expects a VMAF struct
          AbAv1.encode(vmaf)
        rescue
          e ->
            Logger.error("Encoding failed for #{vmaf.video.path}: #{inspect(e)}")
            # Notify of failure manually since AbAv1.encode won't be able to
            Phoenix.PubSub.broadcast(Reencodarr.PubSub, "encoder", {:encoding_failed, vmaf.video, :error})
        end
      end)
    end

    {:noreply, [], state}
  end

  @impl true
  def handle_info({:encoding_complete, video, output_file_from_encoder}, state) do
    handle_encoding_complete(video, output_file_from_encoder)
    {:noreply, [], state}
  end

  @impl true
  def handle_info({:encoding_failed, video, exit_code}, state) do
    handle_encoding_failed(video, exit_code)
    {:noreply, [], state}
  end

  defp handle_encoding_complete(video, output_file_from_encoder) do
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
  end

  defp handle_encoding_failed(video, exit_code) do
    Logger.error("Encoding failed for video #{video.id} with exit code #{exit_code}")
    Media.mark_as_failed(video)
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "encoder", {:encoder, :none})
  end

  defp calculate_intermediate_path(video) do
    original_path = Path.dirname(video.path)
    original_filename = Path.basename(video.path, Path.extname(video.path))
    new_ext = ".mkv"
    intermediate_filename = original_filename <> "_reencoded" <> new_ext
    Path.join(original_path, intermediate_filename)
  end

  defp move_encoder_output_to_intermediate(
         output_file_from_encoder,
         intermediate_reencoded_path,
         video
       ) do
    Logger.info(
      "Moving encoded file from #{output_file_from_encoder} to intermediate path #{intermediate_reencoded_path}"
    )

    case File.rename(output_file_from_encoder, intermediate_reencoded_path) do
      :ok ->
        {:ok, intermediate_reencoded_path}

      {:error, reason} ->
        Logger.error(
          "Failed to move encoded file to intermediate path for video #{video.id}: #{reason}"
        )

        Media.mark_as_failed(video)
        {:error, reason}
    end
  end

  defp finalize_and_sync_video(video, intermediate_reencoded_path) do
    original_path = video.path

    Logger.info(
      "Finalizing re-encode for video #{video.id}: moving from #{intermediate_reencoded_path} to original path #{original_path}"
    )

    case File.rename(intermediate_reencoded_path, original_path) do
      :ok ->
        Logger.info("Successfully finalized re-encode for video #{video.id}")
        # Trigger refresh and rename for the video if it has service info
        if video.service_id && video.service_type do
          Reencodarr.Sync.refresh_and_rename_from_video(video)
        end

      {:error, reason} ->
        Logger.error(
          "Failed to finalize re-encode by renaming to original path for video #{video.id}: #{reason}"
        )

        Media.mark_as_failed(video)
    end
  end
end
