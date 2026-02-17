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

  @doc """
  Force reset the GenServer if it's stuck. Kills the port and process group,
  resets video state, and clears internal state.
  """
  @spec reset_if_stuck() :: :ok | {:error, :not_running}
  def reset_if_stuck do
    case GenServer.whereis(__MODULE__) do
      nil ->
        {:error, :not_running}

      pid ->
        try do
          GenServer.call(pid, :reset_if_stuck, 1000)
        catch
          :exit, _ -> {:error, :timeout}
        end
    end
  end

  @doc """
  Get the current GenServer state for debugging.
  """
  @spec get_state() :: map() | {:error, :not_running}
  def get_state do
    case GenServer.whereis(__MODULE__) do
      nil ->
        {:error, :not_running}

      pid ->
        try do
          GenServer.call(pid, :get_state, 1000)
        catch
          :exit, _ -> {:error, :timeout}
        end
    end
  end

  # GenServer Callbacks
  @impl true
  def init(:ok) do
    # Enable trap_exit to handle port crashes gracefully
    Process.flag(:trap_exit, true)

    # Kill any orphaned ab-av1 encode processes from previous crashes
    Helper.kill_orphaned_processes("ab-av1 encode")

    {:ok,
     %{
       port: :none,
       video: :none,
       vmaf: :none,
       output_file: :none,
       partial_line_buffer: "",
       last_progress: nil,
       output_lines: [],
       encode_args: [],
       os_pid: nil
     }}
  end

  @impl true
  def terminate(reason, state) do
    Logger.warning("Encode GenServer terminating: #{inspect(reason)}")

    # Kill the process group to ensure ffmpeg children are also killed
    Helper.kill_process_group(state.os_pid)

    # Close the port if it's open
    Helper.close_port(state.port)

    # Best-effort: reset video state so it can be re-queued
    if state.video != :none and is_struct(state.video, Reencodarr.Media.Video) do
      case Media.mark_as_crf_searched(state.video) do
        {:ok, _} ->
          Logger.info("Reset video #{state.video.id} to crf_searched state for re-queue")

        {:error, reason} ->
          Logger.error(
            "Failed to reset video #{state.video.id} to crf_searched: #{inspect(reason)}"
          )
      end
    end

    :ok
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
  def handle_call(:reset_if_stuck, _from, state) do
    Logger.warning("Force resetting Encode GenServer - was stuck")

    # Kill the process group and port
    Helper.kill_process_group(state.os_pid)
    Helper.close_port(state.port)

    # Reset video state if we have one
    if state.video != :none and is_struct(state.video, Reencodarr.Media.Video) do
      case Media.mark_as_crf_searched(state.video) do
        {:ok, _} ->
          Logger.info("Reset video #{state.video.id} to crf_searched state")

        {:error, reason} ->
          Logger.error("Failed to reset video #{state.video.id}: #{inspect(reason)}")
      end
    end

    # Notify producer that encoder is available again
    Producer.dispatch_available()

    # Clear state
    clean_state = clear_state(state)

    {:reply, :ok, clean_state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    debug_state = %{
      port_status: if(state.port == :none, do: :available, else: :busy),
      has_video: state.video != :none,
      video_id: if(state.video != :none, do: state.video.id, else: nil),
      os_pid: state.os_pid,
      output_lines_count: length(state.output_lines)
    }

    {:reply, debug_state, state}
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

    # Wrap in try/rescue to prevent crashes from bad data or DB errors
    try do
      ProgressParser.process_line(full_line, state)

      # Try to extract progress data from the line to store as last_progress
      updated_state = extract_and_store_progress(full_line, state)

      # Accumulate output lines (cap at 1024 to avoid memory issues)
      new_output_lines =
        if length(output_lines) < 1024 do
          [full_line | output_lines]
        else
          # Keep most recent 1024 lines
          [full_line | Enum.take(output_lines, 1023)]
        end

      {:noreply, %{updated_state | partial_line_buffer: "", output_lines: new_output_lines}}
    rescue
      e ->
        Logger.error(
          "AbAv1.Encode: Error processing line '#{full_line}': #{Exception.message(e)}"
        )

        # Continue with original state, just clearing the buffer
        {:noreply, %{state | partial_line_buffer: "", output_lines: [full_line | output_lines]}}
    end
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
    # Wrap entire exit handling in try/rescue to ensure state cleanup always happens
    try do
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
    rescue
      e ->
        Logger.error("AbAv1.Encode: Error in exit_status handler: #{Exception.message(e)}")
    end

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

  # Handle port death without exit_status (safety net)
  @impl true
  def handle_info({:EXIT, port, reason}, %{port: port} = state) when port != :none do
    Logger.error("AbAv1.Encode: Port died unexpectedly: #{inspect(reason)}")

    # Broadcast failure
    if state.vmaf != :none do
      Events.broadcast_event(:encoding_completed, %{
        video_id: state.vmaf.video.id,
        result: {:error, :port_died}
      })

      Producer.dispatch_available()
    end

    # Clear state and reset video for re-queue
    {:noreply, clear_state(state)}
  end

  # Ignore EXIT from unknown ports (stale references after restart)
  @impl true
  def handle_info({:EXIT, _port, _reason}, state) do
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
        start_encode_port(vmaf, state)

      {:error, reason} ->
        Logger.error(
          "Failed to mark video #{vmaf.video.id} as encoding: #{inspect(reason)}. Skipping encode."
        )

        state
    end
  end

  defp start_encode_port(vmaf, state) do
    args = build_encode_args(vmaf)
    ext = output_extension(vmaf.video.path)
    output_file = Path.join(Helper.temp_dir(), "#{vmaf.video.id}#{ext}")

    case Helper.open_port(args) do
      {:ok, port} ->
        # Extract OS PID immediately for process group tracking
        os_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, pid} -> pid
            _ -> nil
          end

        broadcast_encoding_started(vmaf, port)
        Process.send_after(self(), :periodic_check, 10_000)

        %{
          state
          | port: port,
            video: vmaf.video,
            vmaf: vmaf,
            output_file: output_file,
            encode_args: args,
            output_lines: [],
            os_pid: os_pid
        }

      {:error, :not_found} ->
        Logger.error("ab-av1 executable not found, cannot encode video #{vmaf.video.id}")
        state
    end
  end

  defp broadcast_encoding_started(vmaf, port) do
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

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
        encode_args: [],
        os_pid: nil
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
