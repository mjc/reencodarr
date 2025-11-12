defmodule Reencodarr.Encoder.Broadway do
  @moduledoc """
  Broadway pipeline for encoding operations.

  This module provides a Broadway pipeline that delegates to the Encode GenServer,
  ensuring single-worker protection and preventing duplicate work.

  The pipeline is configured with:
  - Single concurrency to prevent resource conflicts
  - Rate limiting to avoid overwhelming the system  
  - Delegation to Encode GenServer for actual encoding work
  """

  use Broadway
  require Logger

  alias Broadway.Message
  alias Reencodarr.AbAv1
  alias Reencodarr.Encoder.Broadway.Producer

  @typedoc "VMAF struct for encoding processing"
  @type vmaf :: %{id: integer(), video: map()}

  @typedoc "Broadway pipeline configuration"
  @type config :: keyword()

  # Configuration constants
  @default_config [
    rate_limit_messages: 5,
    rate_limit_interval: 1_000,
    batch_size: 1,
    batch_timeout: 10_000
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
        module: {Producer, []},
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
      ],
      batchers: [
        default: [
          batch_size: config[:batch_size],
          batch_timeout: config[:batch_timeout],
          concurrency: 1
        ]
      ],
      context: %{
        rate_limit_messages: config[:rate_limit_messages],
        rate_limit_interval: config[:rate_limit_interval]
      }
    )
  end

  @doc """
  Check if the encoder pipeline is running.
  """
  @spec running?() :: boolean()
  def running? do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  @doc """
  Pause encoder pipeline - no-op for compatibility.
  """
  @spec pause() :: :ok
  def pause, do: :ok

  @doc """
  Resume encoder pipeline - no-op for compatibility.
  """
  @spec resume() :: :ok
  def resume, do: :ok

  @doc """
  Start encoder pipeline - alias for resume.
  """
  @spec start() :: :ok
  def start, do: :ok

  # Broadway callbacks

  @impl Broadway
  def handle_message(_processor_name, message, _context) do
    # Messages are processed in batches, so we just pass them through
    message
  end

  @impl Broadway
  def handle_batch(_batcher, messages, _batch_info, _context) do
    Logger.info("[Encoder Broadway] Processing batch of #{length(messages)} VMAFs")

    Enum.map(messages, fn message ->
      Logger.info(
        "[Encoder Broadway] Processing VMAF #{message.data.id}: #{Path.basename(message.data.video.path)}"
      )

      case process_vmaf_encoding(message.data) do
        :ok ->
          Logger.info("[Encoder Broadway] Successfully queued VMAF #{message.data.id}")
          message

        {:error, reason} ->
          Logger.warning("Encoding failed for VMAF #{inspect(message.data)}: #{reason}")
          Message.failed(message, reason)
      end
    end)
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
    Logger.info(
      "[Encoder Broadway] Starting encode for VMAF #{vmaf.id}: #{Path.basename(vmaf.video.path)}"
    )

    # Delegate to Encode GenServer - it handles all the encoding logic
    # This ensures single-worker protection (only one encode at a time)
    result = AbAv1.encode(vmaf)

    Logger.info(
      "[Encoder Broadway] Encode queued for VMAF #{vmaf.id}, result: #{inspect(result)}"
    )

    :ok
  rescue
    exception ->
      error_message =
        "Exception during encoding for VMAF #{vmaf.id}: #{Exception.message(exception)}"

      Logger.error(error_message)

      {:error, error_message}
  end
end
