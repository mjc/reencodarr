defmodule Reencodarr.AbAv1.Encode do
  @moduledoc """
  GenServer for handling video encoding operations using ab-av1.

  This module manages the encoding process for videos based on VMAF data,
  handles file operations, and coordinates with the media database.
  """

  use GenServer

  alias Reencodarr.AbAv1.Helper
  alias Reencodarr.{Media, Repo, Rules, Sync, Telemetry}

  require Logger

  # Public API
  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec encode(Media.Vmaf.t()) :: :ok
  def encode(vmaf) do
    Logger.info("Starting encode for VMAF: #{vmaf.id}")
    GenServer.cast(__MODULE__, {:encode, vmaf})
  end

  def running? do
    case GenServer.call(__MODULE__, :running?) do
      :running -> true
      :not_running -> false
    end
  end

  # GenServer Callbacks
  @impl true
  def init(:ok) do
    {:ok,
     %{
       port: :none,
       video: :none,
       vmaf: :none,
       output_file: :none,
       partial_line_buffer: ""
     }}
  end

  @impl true
  def handle_call(:running?, _from, %{port: port} = state) do
    status = if port == :none, do: :not_running, else: :running
    {:reply, status, state}
  end

  @impl true
  def handle_cast(
        {:encode, %Media.Vmaf{params: _params} = vmaf},
        %{port: :none} = state
      ) do
    new_state = prepare_encode_state(vmaf, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:encode, %Media.Vmaf{} = vmaf}, %{port: port} = state) when port != :none do
    Logger.info("Encoding is already in progress, skipping new encode request.")

    # Publish a skipped event since this request was rejected
    Phoenix.PubSub.broadcast(
      Reencodarr.PubSub,
      "encoding_events",
      {:encoding_completed, vmaf.id, :skipped}
    )

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {port, {:data, {:eol, data}}},
        %{port: port, partial_line_buffer: buffer} = state
      ) do
    full_line = buffer <> data
    process_line(full_line, state)
    {:noreply, %{state | partial_line_buffer: ""}}
  end

  @impl true
  def handle_info(
        {port, {:data, {:noeol, message}}},
        %{port: port, partial_line_buffer: buffer} = state
      ) do
    Logger.debug("Received partial data chunk, buffering.")
    new_buffer = buffer <> message
    {:noreply, %{state | partial_line_buffer: new_buffer}}
  end

  @impl true
  def handle_info(
        {port, {:exit_status, exit_code}},
        %{port: port, vmaf: vmaf, output_file: output_file} = state
      ) do
    result =
      case exit_code do
        0 -> {:ok, :success}
        1 -> {:ok, :success}
        _ -> {:error, exit_code}
      end

    Logger.debug("Exit status: #{inspect(result)}")

    # Publish completion event to PubSub
    pubsub_result = if result == {:ok, :success}, do: :success, else: {:error, exit_code}

    Phoenix.PubSub.broadcast(
      Reencodarr.PubSub,
      "encoding_events",
      {:encoding_completed, vmaf.id, pubsub_result}
    )

    if result == {:ok, :success} do
      notify_encoder_success(vmaf.video, output_file)
    else
      notify_encoder_failure(vmaf.video, exit_code)
    end

    new_state = %{
      state
      | port: :none,
        video: :none,
        vmaf: :none,
        output_file: nil,
        partial_line_buffer: ""
    }

    {:noreply, new_state}
  end

  # Private Helper Functions
  defp prepare_encode_state(vmaf, state) do
    args = build_encode_args(vmaf)
    output_file = Path.join(Helper.temp_dir(), "#{vmaf.video.id}.mkv")

    Logger.info("Starting encode with args: #{inspect(args)}")

    %{
      state
      | port: Helper.open_port(args),
        video: vmaf.video,
        vmaf: vmaf,
        output_file: output_file
    }
  end

  defp build_encode_args(vmaf) do
    base_args = [
      "encode",
      "--crf",
      to_string(vmaf.crf),
      "-o",
      Path.join(Helper.temp_dir(), "#{vmaf.video.id}.mkv"),
      "-i",
      vmaf.video.path
    ]

    rule_args =
      vmaf.video
      |> Rules.apply()
      |> Enum.flat_map(fn
        {k, v} -> [to_string(k), to_string(v)]
      end)

    base_args ++ rule_args
  end

  defp notify_encoder_success(video, output_file) do
    # Emit telemetry event for completion
    Telemetry.emit_encoder_completed()

    # Do post-encoding cleanup work
    handle_post_encoding_cleanup(video, output_file)
  end

  defp notify_encoder_failure(video, exit_code) do
    # Emit telemetry event for failure
    Telemetry.emit_encoder_failed(exit_code, video)
  end

  # Post-encoding cleanup functions
  defp handle_post_encoding_cleanup(video, output_file) do
    intermediate_path = calculate_intermediate_path(video)

    case move_encoder_output_to_intermediate(output_file, intermediate_path, video) do
      {:ok, actual_path} -> process_intermediate_ok(video, actual_path)
      {:error, _} -> :ok
    end
  end

  # Processes successful intermediate move: reload and mark re-encoded
  defp process_intermediate_ok(video, actual_path) do
    case Repo.reload(video) do
      nil -> Logger.error("Failed to reload video #{video.id}: Video not found.")
      reloaded -> process_reloaded_video(reloaded, actual_path)
    end
  end

  # Handles marking the reloaded video and finalizing
  defp process_reloaded_video(video, actual_path) do
    case Media.mark_as_reencoded(video) do
      {:ok, _} ->
        Logger.info("Successfully marked video #{video.id} as re-encoded")
        finalize_and_sync_video(video, actual_path)

      {:error, reason} ->
        Logger.error("Failed to mark video #{video.id} as re-encoded: #{inspect(reason)}")
    end
  end

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
        handle_exdev_rename(source, destination, log_prefix, video)

      {:error, reason} ->
        handle_rename_error(reason, source, destination, log_prefix, video)
    end
  end

  # Handle cross-device rename by copying then deleting
  defp handle_exdev_rename(source, destination, log_prefix, video) do
    Logger.info(
      "[#{log_prefix}] Cross-device rename for #{source} to #{destination} (video #{video.id}). Attempting copy and delete."
    )

    case File.cp(source, destination) do
      :ok ->
        Logger.info(
          "[#{log_prefix}] Successfully copied #{source} to #{destination} for video #{video.id}"
        )

        handle_post_copy(source, log_prefix, video)

      {:error, cp_reason} ->
        Logger.error(
          "[#{log_prefix}] Failed to copy #{source} to #{destination} for video #{video.id}: #{cp_reason}. File remains at #{source}."
        )

        {:error, cp_reason}
    end
  end

  # After successful copy, attempt to remove original
  defp handle_post_copy(source, log_prefix, video) do
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
  end

  # Log rename error and return
  defp handle_rename_error(reason, source, destination, log_prefix, video) do
    Logger.error(
      "[#{log_prefix}] Failed to rename #{source} to #{destination} for video #{video.id}: #{reason}. File remains at #{source}."
    )

    {:error, reason}
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

    Sync.refresh_and_rename_from_video(video)
  end

  def process_line(data, state) do
    cond do
      captures = Regex.named_captures(~r/\[.*\] encoding (?<filename>\d+\.mkv)/, data) ->
        file = captures["filename"]
        extname = Path.extname(file)
        id = String.to_integer(Path.basename(file, extname))

        video = Media.get_video!(id)
        filename = video.path |> Path.basename()

        # Emit telemetry event for encoding start
        Telemetry.emit_encoder_started(filename)

      captures =
          Regex.named_captures(
            ~r/\[.*\]\s+(?<percent>\d+)%\s*,\s*(?<fps>[\d\.]+)\s*fps,\s*eta\s*(?<eta>\d+)\s*(?<unit>minutes|seconds|hours|days|weeks|months|years)/,
            data
          ) ->
        _eta_seconds =
          Helper.convert_to_seconds(String.to_integer(captures["eta"]), captures["unit"])

        human_readable_eta = "#{captures["eta"]} #{captures["unit"]}"
        filename = Path.basename(state.video.path)

        # Emit telemetry event for encoding progress
        progress = %Reencodarr.Statistics.EncodingProgress{
          percent: String.to_integer(captures["percent"]),
          eta: human_readable_eta,
          fps: parse_fps(captures["fps"]),
          filename: filename
        }

        Telemetry.emit_encoder_progress(progress)

      _captures =
          Regex.named_captures(~r/Encoded\s(?<size>[\d\.]+\s\w+)\s\((?<percent>\d+)%\)/, data) ->
        # File size progress - not doing anything specific here currently
        :ok

      true ->
        # Non-matching lines are ignored
        :ok
    end
  end

  defp parse_fps(fps_string) do
    fps_string
    |> then(fn str ->
      if String.contains?(str, ".") do
        str
      else
        str <> ".0"
      end
    end)
    |> String.to_float()
    |> Float.round()
  end
end
