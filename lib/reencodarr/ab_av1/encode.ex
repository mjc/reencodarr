defmodule Reencodarr.AbAv1.Encode do
  @moduledoc """
  GenServer for handling video encoding operations using ab-av1.

  This module manages the encoding process for videos, processes output data,
  handles file operations, and coordinates with the media database.
  """

  use GenServer

  alias Reencodarr.AbAv1.Helper
  alias Reencodarr.{Media, PostProcessor, ProgressParser, Rules, Telemetry}

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
    Logger.debug("AbAv1.Encode: Received complete line: #{inspect(full_line)}")
    Logger.debug("AbAv1.Encode: Current state - video: #{inspect(state.video && state.video.path)}, vmaf: #{inspect(state.vmaf && state.vmaf.id)}")

    # Log specifically for progress-looking lines
    cond do
      String.contains?(full_line, "%") and String.contains?(full_line, "fps") ->
        Logger.warning("AbAv1.Encode: POTENTIAL PROGRESS LINE: #{inspect(full_line)}")

      String.contains?(full_line, "encoding") ->
        Logger.debug("AbAv1.Encode: ENCODING STATUS LINE: #{inspect(full_line)}")

      true ->
        Logger.debug("AbAv1.Encode: OTHER LINE: #{inspect(full_line)}")
    end

    Logger.debug("AbAv1.Encode: Calling ProgressParser.process_line")
    ProgressParser.process_line(full_line, state)
    Logger.debug("AbAv1.Encode: ProgressParser.process_line completed")
    {:noreply, %{state | partial_line_buffer: ""}}
  end

  @impl true
  def handle_info(
        {port, {:data, {:noeol, message}}},
        %{port: port, partial_line_buffer: buffer} = state
      ) do
    Logger.debug("AbAv1.Encode: Received partial data chunk: #{inspect(message)}, current buffer: #{inspect(buffer)}")
    new_buffer = buffer <> message
    Logger.debug("AbAv1.Encode: New buffer after append: #{inspect(new_buffer)}")

    # Check if the buffer contains progress-like content
    if String.contains?(new_buffer, "%") or String.contains?(new_buffer, "fps") or String.contains?(new_buffer, "eta") do
      Logger.warning("AbAv1.Encode: Buffer contains progress-like content: #{inspect(new_buffer)}")
    end

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
  def handle_info(:periodic_check, %{port: port, video: video} = state) when port != :none do
    Logger.debug("AbAv1.Encode: Periodic check - encoding still active for video: #{video.path}")

    # Emit a minimal progress update to show the encoding is still running
    # This will at least update the UI to show the process is active
    filename = Path.basename(video.path)
    progress = %Reencodarr.Statistics.EncodingProgress{
      percent: 1,  # Show minimal progress to indicate activity
      eta: "Unknown",
      fps: 0,
      filename: filename
    }

    Logger.debug("AbAv1.Encode: Emitting keepalive progress update")
    Telemetry.emit_encoder_progress(progress)

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
  defp prepare_encode_state(vmaf, state) do
    args = build_encode_args(vmaf)
    output_file = Path.join(Helper.temp_dir(), "#{vmaf.video.id}.mkv")

    Logger.debug("AbAv1.Encode: Starting encode with args: #{inspect(args)}")
    Logger.debug("AbAv1.Encode: Output file: #{output_file}")
    Logger.debug("AbAv1.Encode: Video path: #{vmaf.video.path}")
    Logger.debug("AbAv1.Encode: VMAF ID: #{vmaf.id}, CRF: #{vmaf.crf}")

    port = Helper.open_port(args)
    Logger.debug("AbAv1.Encode: Port opened successfully: #{inspect(port)}")

    # Set up a periodic timer to check if we're still alive and potentially emit progress
    Process.send_after(self(), :periodic_check, 10_000)  # Check every 10 seconds

    %{
      state
      | port: port,
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

    # Use PostProcessor for cleanup work
    PostProcessor.process_encoding_success(video, output_file)
  end

  defp notify_encoder_failure(video, exit_code) do
    # Emit telemetry event for failure
    Telemetry.emit_encoder_failed(exit_code, video)
  end
end
