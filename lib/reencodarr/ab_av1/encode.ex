defmodule Reencodarr.AbAv1.Encode do
  @moduledoc """
  GenServer for handling video encoding operations using ab-av1.

  This module manages the encoding process for videos, processes output data,
  handles file operations, and coordinates with the media database.
  """

  use GenServer

  alias Reencodarr.AbAv1.{Helper, ProgressParser}
  alias Reencodarr.Encoder.Broadway.Producer
  alias Reencodarr.{Media, PostProcessor, Telemetry}

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
  def handle_cast({:encode, vmaf}, state) do
    args = build_encode_args(vmaf)

    case Helper.open_port(args) do
      {:ok, port} ->
        Telemetry.emit_encoder_started(vmaf.video.path)

        output_file = Path.join(Helper.temp_dir(), "#{vmaf.video.id}.mkv")

        new_state = %{
          state
          | port: port,
            video: vmaf.video,
            vmaf: vmaf,
            output_file: output_file
        }

        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Failed to open port: #{inspect(reason)}")
        {:noreply, state}
    end
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
    vmaf_params = if vmaf.params && is_list(vmaf.params), do: vmaf.params, else: []

    # Pass base_args to Rules.build_args so it can handle deduplication properly
    Reencodarr.Rules.build_args(vmaf.video, :encode, vmaf_params, base_args)
  end

  # Test helper functions
  def build_encode_args_for_test(vmaf), do: build_encode_args(vmaf)

  def filter_input_output_args_for_test(args) do
    # Convert args list to tuples and filter out input/output flags
    args
    |> Enum.chunk_every(2)
    |> Enum.reject(fn
      ["--input", _] -> true
      ["-i", _] -> true
      ["--output", _] -> true
      ["-o", _] -> true
      _ -> false
    end)
    |> List.flatten()
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
