defmodule Reencodarr.AbAv1.Encode do
  @moduledoc """
  GenServer for handling video encoding operations using ab-av1.

  This module manages the encoding process for videos based on VMAF data,
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
    ProgressParser.process_line(full_line, state)
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

    # Use PostProcessor for cleanup work
    PostProcessor.process_encoding_success(video, output_file)
  end

  defp notify_encoder_failure(video, exit_code) do
    # Emit telemetry event for failure
    Telemetry.emit_encoder_failed(exit_code, video)
  end
end
