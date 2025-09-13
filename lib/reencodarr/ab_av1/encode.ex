defmodule Reencodarr.AbAv1.Encode do
  @moduledoc """
  GenServer for handling video encoding operations using ab-av1.

  This module manages the encoding process for videos, processes output data,
  handles file operations, and coordinates with the media database.
  """

  use GenServer

  alias Reencodarr.AbAv1.Helper
  alias Reencodarr.AbAv1.ProgressParser
  alias Reencodarr.Encoder.Broadway.Producer
  alias Reencodarr.{Media, PostProcessor, Telemetry, TelemetryReporter}

  require Logger

  # Public API
  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec encode(Media.Vmaf.t()) :: :ok
  def encode(vmaf) do
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
    ProgressParser.process_line(full_line, state)
    {:noreply, %{state | partial_line_buffer: ""}}
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
        %{port: port, vmaf: vmaf, output_file: output_file} = state
      ) do
    result =
      case exit_code do
        0 -> {:ok, :success}
        _ -> {:error, exit_code}
      end

    # Publish completion event to PubSub
    pubsub_result = if result == {:ok, :success}, do: :success, else: {:error, exit_code}

    Phoenix.PubSub.broadcast(
      Reencodarr.PubSub,
      "encoding_events",
      {:encoding_completed, vmaf.id, pubsub_result}
    )

    # Notify the Broadway producer that encoding is now available
    Producer.dispatch_available()

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
    # Get the last known progress from the telemetry system to preserve ETA
    last_progress =
      case TelemetryReporter.get_progress_state() do
        %{encoding_progress: %{eta: eta, percent: percent, fps: fps}} when eta != 0 ->
          %{eta: eta, percent: percent, fps: fps}

        _ ->
          %{eta: "Unknown", percent: 1, fps: 0}
      end

    # Emit a minimal progress update to show the encoding is still running
    # This preserves the last known ETA instead of always showing "Unknown"
    filename = Path.basename(video.path)

    progress = %Reencodarr.Statistics.EncodingProgress{
      percent: last_progress.percent,
      eta: last_progress.eta,
      fps: last_progress.fps,
      filename: filename
    }

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

    port = Helper.open_port(args)

    # Set up a periodic timer to check if we're still alive and potentially emit progress
    # Check every 10 seconds
    Process.send_after(self(), :periodic_check, 10_000)

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
      "--output",
      Path.join(Helper.temp_dir(), "#{vmaf.video.id}.mkv"),
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
