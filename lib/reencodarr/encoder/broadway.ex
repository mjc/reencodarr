defmodule Reencodarr.Encoder.Broadway do
  @moduledoc """
  Broadway pipeline for encoding operations.

  This module provides a Broadway pipeline that respects the single-worker
  limitation of the encoding GenServer, preventing duplicate work.

  The pipeline is configured with:
  - Single concurrency to prevent resource conflicts
  - Rate limiting to avoid overwhelming the system
  - Proper error handling and telemetry
  - Configurable batch processing
  """

  use Broadway
  require Logger

  alias Broadway.Message

  @typedoc "VMAF struct for encoding processing"
  @type vmaf :: %{id: integer(), video: map()}

  @typedoc "Broadway pipeline configuration"
  @type config :: keyword()

  # Configuration constants
  @default_config [
    rate_limit_messages: 5,
    rate_limit_interval: 1_000
  ]

  @doc """
  Start the Broadway pipeline with configurable options.

  ## Options
    * `:rate_limit_messages` - Number of messages allowed per interval (default: 5)
    * `:rate_limit_interval` - Rate limit interval in milliseconds (default: 1000)
    * `:batch_size` - Number of messages per batch (default: 1)
    * `:batch_timeout` - Batch timeout in milliseconds (default: 10000)

  ## Examples
      iex> Reencodarr.Encoder.Broadway.start_link([])
      {:ok, pid}

      iex> Reencodarr.Encoder.Broadway.start_link([rate_limit_messages: 3])
      {:ok, pid}
  """
  @spec start_link(config()) :: GenServer.on_start()
  def start_link(opts) do
    app_config = Application.get_env(:reencodarr, __MODULE__, [])
    config = @default_config |> Keyword.merge(app_config) |> Keyword.merge(opts)

    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {Reencodarr.Encoder.Broadway.Producer, []},
        transformer: {__MODULE__, :transform, []},
        rate_limiting: [
          allowed_messages: config[:rate_limit_messages],
          interval: config[:rate_limit_interval]
        ]
      ],
      processors: [
        default: [
          concurrency: 1,
          max_demand: 1
        ]
      ]
    )
  end

  @doc """
  Add a VMAF to the pipeline for encoding processing.

  ## Parameters
    * `vmaf` - VMAF struct containing id and video data

  ## Examples
      iex> vmaf = %{id: 1, video: %{path: "/path/to/video.mp4"}}
      iex> Reencodarr.Encoder.Broadway.process_vmaf(vmaf)
      :ok
  """
  @spec process_vmaf(vmaf()) :: :ok | {:error, term()}
  def process_vmaf(vmaf) do
    case Reencodarr.Encoder.Broadway.Producer.add_vmaf(vmaf) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Check if the encoder pipeline is running (not paused).

  ## Examples
      iex> Reencodarr.Encoder.Broadway.running?()
      true
  """
  @spec running?() :: boolean()
  def running? do
    with pid when is_pid(pid) <- Process.whereis(__MODULE__),
         true <- Process.alive?(pid) do
      Reencodarr.Encoder.Broadway.Producer.running?()
    else
      _ -> false
    end
  end

  @doc """
  Pause the encoder pipeline.

  ## Examples
      iex> Reencodarr.Encoder.Broadway.pause()
      :ok
  """
  @spec pause() :: :ok | {:error, term()}
  def pause do
    Reencodarr.Encoder.Broadway.Producer.pause()
  end

  @doc """
  Resume the encoder pipeline.

  ## Examples
      iex> Reencodarr.Encoder.Broadway.resume()
      :ok
  """
  @spec resume() :: :ok | {:error, term()}
  def resume do
    Reencodarr.Encoder.Broadway.Producer.resume()
  end

  @doc """
  Start the encoder pipeline.

  Alias for `resume/0` to maintain API compatibility.
  """
  @spec start() :: :ok | {:error, term()}
  def start, do: resume()

  # Broadway callbacks

  @impl Broadway
  def handle_message(_processor_name, message, _context) do
    # Start encoding asynchronously but wait for completion to maintain single-concurrency
    task = Task.async(fn ->
      process_vmaf_encoding(message.data)
    end)

    # Wait for the task to complete
    case Task.await(task, :infinity) do
      :ok ->
        Logger.info("Broadway: Encoding completed successfully for VMAF #{message.data.id}")
        message

      {:error, reason} ->
        Logger.warning("Broadway: Encoding failed for VMAF #{message.data.id}: #{reason}")
        # Don't fail the Broadway message to avoid pausing the pipeline
        # The failure is already logged and reported via PubSub in process_vmaf_encoding
        message
    end
  end

  @doc """
  Transform raw VMAF data into a Broadway message.

  This function is called by the Broadway producer to transform
  events into messages that can be processed by the pipeline.
  """
  @spec transform(vmaf(), keyword()) :: Message.t()
  def transform(vmaf, _opts) do
    %Message{
      data: vmaf,
      acknowledger: Broadway.NoopAcknowledger.init()
    }
  end

  # Private functions

  @spec process_vmaf_encoding(vmaf()) :: :ok | {:error, term()}
  defp process_vmaf_encoding(vmaf) do
    Logger.info("Broadway: Starting encoding for VMAF #{vmaf.id}: #{vmaf.video.path}")

    # Import necessary modules
    alias Reencodarr.AbAv1.Helper
    alias Reencodarr.{PostProcessor, Rules, Telemetry}

    try do
      # Build encoding arguments
      args = build_encode_args(vmaf)
      output_file = Path.join(Helper.temp_dir(), "#{vmaf.video.id}.mkv")

      Logger.debug("Broadway: Starting encode with args: #{inspect(args)}")
      Logger.debug("Broadway: Output file: #{output_file}")

      # Open port and handle encoding
      port = Helper.open_port(args)
      Logger.debug("Broadway: Port opened successfully: #{inspect(port)}")

      # Handle the encoding process synchronously within Broadway
      result = handle_encoding_process(port, vmaf, output_file)

      case result do
        {:ok, :success} ->
          case notify_encoding_success(vmaf.video, output_file) do
            {:ok, :success} ->
              Logger.info("Broadway: Encoding and post-processing completed successfully for VMAF #{vmaf.id}")
              :ok
            {:error, reason} ->
              Logger.error("Broadway: Encoding succeeded but post-processing failed for VMAF #{vmaf.id}: #{reason}")
              {:error, "Post-processing failed: #{reason}"}
          end

        {:error, exit_code} ->
          notify_encoding_failure(vmaf.video, exit_code)

          Logger.error(
            "Broadway: Encoding failed for VMAF #{vmaf.id} with exit code: #{exit_code}"
          )

          {:error, "Encoding failed with exit code #{exit_code}"}
      end
    rescue
      exception ->
        error_message =
          "Exception during Broadway encoding for VMAF #{vmaf.id}: #{Exception.message(exception)}"

        Logger.error(error_message)
        {:error, error_message}
    end
  end

  @spec handle_encoding_process(port(), vmaf(), String.t()) ::
          {:ok, :success} | {:error, integer()}
  defp handle_encoding_process(port, vmaf, output_file) do
    # Initialize state for progress tracking
    state = %{
      port: port,
      video: vmaf.video,
      vmaf: vmaf,
      output_file: output_file,
      partial_line_buffer: ""
    }

    # Process port messages until completion
    process_port_messages(state)
  end

  @spec process_port_messages(map()) :: {:ok, :success} | {:error, integer()}
  defp process_port_messages(state) do
    receive do
      {port, {:data, {:eol, data}}} when port == state.port ->
        full_line = state.partial_line_buffer <> data
        Reencodarr.ProgressParser.process_line(full_line, state)
        new_state = %{state | partial_line_buffer: ""}

        # Yield control back to the scheduler to allow Broadway metrics to update
        Process.sleep(1)
        process_port_messages(new_state)

      {port, {:data, {:noeol, message}}} when port == state.port ->
        new_buffer = state.partial_line_buffer <> message
        new_state = %{state | partial_line_buffer: new_buffer}
        process_port_messages(new_state)

      {port, {:exit_status, exit_code}} when port == state.port ->
        Logger.debug("Broadway: Process exit status: #{exit_code}")

        # Publish completion event to PubSub
        pubsub_result = if exit_code in [0, 1], do: :success, else: {:error, exit_code}

        Phoenix.PubSub.broadcast(
          Reencodarr.PubSub,
          "encoding_events",
          {:encoding_completed, state.vmaf.id, pubsub_result}
        )

        # Return result based on exit code
        if exit_code in [0, 1] do
          {:ok, :success}
        else
          {:error, exit_code}
        end
    after
      300_000 ->
        # Timeout after 5 minutes of no activity (encoding can take a long time)
        Logger.error("Broadway: Encoding timeout for VMAF #{state.vmaf.id}")
        Port.close(state.port)
        {:error, :timeout}
    end
  end

  @spec build_encode_args(vmaf()) :: [String.t()]
  defp build_encode_args(vmaf) do
    alias Reencodarr.{Rules, AbAv1.Helper}

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

  @spec notify_encoding_success(map(), String.t()) :: {:ok, :success} | {:error, atom()}
  defp notify_encoding_success(video, output_file) do
    alias Reencodarr.{PostProcessor, Telemetry}

    # Emit telemetry event for completion
    Telemetry.emit_encoder_completed()

    # Use PostProcessor for cleanup work and return its result
    PostProcessor.process_encoding_success(video, output_file)
  end

  @spec notify_encoding_failure(map(), integer()) :: :ok
  defp notify_encoding_failure(video, exit_code) do
    alias Reencodarr.{PostProcessor, Telemetry}

    # Emit telemetry event for failure
    Telemetry.emit_encoder_failed(exit_code, video)

    # Mark the video as failed and handle cleanup
    PostProcessor.process_encoding_failure(video, exit_code)
  end
end
