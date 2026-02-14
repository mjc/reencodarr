defmodule Reencodarr.AbAv1.Encode do
  @moduledoc """
  GenServer for handling video encoding operations using ab-av1.

  This module manages the encoding process for videos, processes output data,
  handles file operations, and coordinates with the media database.
  """

  use GenServer

  alias Reencodarr.AbAv1.Helper
  alias Reencodarr.AbAv1.ProgressParser
  alias Reencodarr.Core.Retry
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Encoder.Broadway.Producer
  alias Reencodarr.{Media, PostProcessor}
  alias Reencodarr.Media.Vmaf

  require Logger

  # Public API
  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec encode(Media.Vmaf.t()) :: :ok
  def encode(vmaf) do
    GenServer.cast(__MODULE__, {:encode, vmaf})
  end

  def running? do
    # Simplified - just check if process exists and is alive
    case GenServer.whereis(__MODULE__) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  @spec available?() :: boolean()
  def available? do
    # Check if encoder is available (not currently encoding)
    case GenServer.whereis(__MODULE__) do
      nil ->
        false

      pid ->
        try do
          GenServer.call(pid, :available?, 100)
        catch
          :exit, _ -> false
        end
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
       partial_line_buffer: "",
       last_progress: nil,
       output_lines: [],
       encode_args: []
     }}
  end

  @impl true
  def handle_call(:running?, _from, %{port: port} = state) do
    status = if port == :none, do: :not_running, else: :running
    {:reply, status, state}
  end

  @impl true
  def handle_call(:available?, _from, %{port: port} = state) do
    available = port == :none
    {:reply, available, state}
  end

  @impl true
  def handle_cast(
        {:encode, %Vmaf{params: _params} = vmaf},
        %{port: :none} = state
      ) do
    new_state = prepare_encode_state(vmaf, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:encode, %Vmaf{} = _vmaf}, %{port: port} = state) when port != :none do
    Logger.info("Encoding is already in progress, skipping new encode request.")

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {port, {:data, {:eol, data}}},
        %{port: port, partial_line_buffer: buffer, output_lines: output_lines} = state
      ) do
    full_line = buffer <> data
    ProgressParser.process_line(full_line, state)

    # Try to extract progress data from the line to store as last_progress
    updated_state = extract_and_store_progress(full_line, state)

    # Accumulate output lines (cap at 200 to avoid memory issues)
    new_output_lines =
      if length(output_lines) < 200 do
        [full_line | output_lines]
      else
        # Keep most recent 200 lines
        [full_line | Enum.take(output_lines, 199)]
      end

    {:noreply, %{updated_state | partial_line_buffer: "", output_lines: new_output_lines}}
  end

  @impl true
  def handle_info(
        {port, {:data, {:noeol, message}}},
        %{port: port, partial_line_buffer: buffer} = state
      ) do
    new_buffer = buffer <> message
    {:noreply, %{state | partial_line_buffer: new_buffer}}
  end

  @impl true
  def handle_info(
        {port, {:exit_status, exit_code}},
        %{
          port: port,
          vmaf: vmaf,
          output_file: output_file,
          encode_args: encode_args,
          output_lines: output_lines
        } = state
      ) do
    # Broadcast encoding completion to Dashboard Events
    pubsub_result = if exit_code == 0, do: :success, else: {:error, exit_code}

    Events.broadcast_event(:encoding_completed, %{
      video_id: vmaf.video.id,
      result: pubsub_result
    })

    # Notify the Broadway producer that encoding is now available
    Producer.dispatch_available()

    # Handle success/failure with automatic retry on DB busy
    Retry.retry_on_db_busy(fn ->
      if exit_code == 0 do
        notify_encoder_success(vmaf.video, output_file)
      else
        notify_encoder_failure(vmaf.video, exit_code, encode_args, output_lines)
      end
    end)

    # Always clear state after handling exit (retry succeeded or max attempts reached)
    {:noreply, clear_state(state)}
  end

  # Catch-all for any other port messages
  @impl true
  def handle_info({port, message}, %{port: port} = state) do
    Logger.warning("AbAv1.Encode: Received unexpected port message: #{inspect(message)}")
    {:noreply, state}
  end

  # Periodic check to see if encoding is still active
  @impl true
  def handle_info(:periodic_check, %{port: :none} = state) do
    # Encoding not active, don't schedule another check
    {:noreply, state}
  end

  @impl true
  def handle_info(
        :periodic_check,
        %{port: port, video: video, last_progress: last_progress} = state
      )
      when port != :none do
    # Broadcast the last known progress to keep dashboard alive during long encodings
    # Only broadcast if we have real progress data, otherwise let the dashboard handle the silence
    if last_progress do
      Events.broadcast_event(:encoding_progress, %{
        video_id: video.id,
        percent: last_progress.percent,
        fps: last_progress.fps,
        eta: last_progress.eta,
        filename: Path.basename(video.path)
      })

      # Also ensure encoder status shows as active
      Events.broadcast_event(:encoder_started, %{})
    end

    # Schedule the next check
    Process.send_after(self(), :periodic_check, 10_000)
    {:noreply, state}
  end

  # Catch-all for any other messages
  @impl true
  def handle_info(message, state) do
    Logger.warning("AbAv1.Encode: Received unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  # Private Helper Functions

  # Determine output extension based on input file
  # MP4 files output as MP4, everything else outputs as MKV
  defp output_extension(video_path) do
    case Path.extname(video_path) |> String.downcase() do
      ".mp4" -> ".mp4"
      _ -> ".mkv"
    end
  end

  defp prepare_encode_state(vmaf, state) do
    # Mark video as encoding BEFORE starting the port to prevent duplicate dispatches
    case Media.mark_as_encoding(vmaf.video) do
      {:ok, _updated_video} ->
        args = build_encode_args(vmaf)
        ext = output_extension(vmaf.video.path)
        output_file = Path.join(Helper.temp_dir(), "#{vmaf.video.id}#{ext}")

        port = Helper.open_port(args)

        # Get OS PID from port for health monitoring
        os_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, pid} -> pid
            _ -> nil
          end

        # Broadcast encoding started to Dashboard Events (includes OS PID for health check + metadata)
        Events.broadcast_event(:encoding_started, %{
          video_id: vmaf.video.id,
          filename: Path.basename(vmaf.video.path),
          os_pid: os_pid,
          video_size: vmaf.video.size,
          width: vmaf.video.width,
          height: vmaf.video.height,
          hdr: vmaf.video.hdr,
          video_codecs: vmaf.video.video_codecs,
          crf: vmaf.crf,
          vmaf_score: vmaf.score,
          predicted_percent: vmaf.percent,
          predicted_savings: vmaf.savings
        })

        # Set up a periodic timer to check if we're still alive and potentially emit progress
        # Check every 10 seconds
        Process.send_after(self(), :periodic_check, 10_000)

        %{
          state
          | port: port,
            video: vmaf.video,
            vmaf: vmaf,
            output_file: output_file,
            encode_args: args,
            output_lines: []
        }

      {:error, reason} ->
        Logger.error(
          "Failed to mark video #{vmaf.video.id} as encoding: #{inspect(reason)}. Skipping encode."
        )

        state
    end
  end

  defp build_encode_args(vmaf) do
    ext = output_extension(vmaf.video.path)

    base_args = [
      "encode",
      "--crf",
      to_string(vmaf.crf),
      "--output",
      Path.join(Helper.temp_dir(), "#{vmaf.video.id}#{ext}"),
      "--input",
      vmaf.video.path
    ]

    # Get rule-based arguments from centralized Rules module
    # Extract VMAF params for use in Rules.build_args
    vmaf_params = extract_vmaf_params(vmaf)

    # Pass base_args to Rules.build_args so it can handle deduplication properly
    Reencodarr.Rules.build_args(vmaf.video, :encode, vmaf_params, base_args)
  end

  # Helper function to extract VMAF params with proper pattern matching
  defp extract_vmaf_params(%{params: params}) when is_list(params), do: params
  defp extract_vmaf_params(_), do: []

  # Test helper function to expose build_encode_args for testing
  if Mix.env() == :test do
    def build_encode_args_for_test(vmaf), do: build_encode_args(vmaf)
  end

  defp clear_state(state) do
    %{
      state
      | port: :none,
        video: :none,
        vmaf: :none,
        output_file: nil,
        partial_line_buffer: "",
        last_progress: nil,
        output_lines: [],
        encode_args: []
    }
  end

  defp notify_encoder_success(video, output_file) do
    # Use PostProcessor for cleanup work
    PostProcessor.process_encoding_success(video, output_file)
  end

  defp notify_encoder_failure(video, exit_code, encode_args, output_lines) do
    # Build command context for failure diagnostics
    # Reverse output_lines since we prepended them
    context =
      Reencodarr.FailureTracker.build_command_context(
        encode_args,
        Enum.reverse(output_lines),
        %{exit_code: exit_code}
      )

    PostProcessor.process_encoding_failure(video, exit_code, context)
  end

  # Extract progress data from a line and store it for periodic updates
  defp extract_and_store_progress(line, state) do
    # Simple regex to match progress lines: "X%, Y fps, eta Z"
    progress_regex =
      ~r/(?<percent>\d+(?:\.\d+)?)%,\s+(?<fps>\d+(?:\.\d+)?)\s+fps.*?eta\s+(?<eta>[^,\n]+)/

    case Regex.named_captures(progress_regex, line) do
      %{"percent" => percent_str, "fps" => fps_str, "eta" => eta_str} ->
        progress_data = %{
          percent: String.to_float(percent_str),
          fps: String.to_float(fps_str),
          eta: String.trim(eta_str)
        }

        %{state | last_progress: progress_data}

      nil ->
        # No progress found in this line, keep existing state
        state
    end
  rescue
    # If parsing fails, just return the original state
    _ -> state
  end
end
