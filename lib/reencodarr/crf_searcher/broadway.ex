defmodule Reencodarr.CrfSearcher.Broadway do
  @moduledoc """
  Broadway pipeline for CRF search operations.

  This module provides a Broadway pipeline that respects the single-worker
  limitation of the CRF search GenServer, preventing duplicate work.

  The pipeline is configured with:
  - Single concurrency to prevent resource conflicts
  - Rate limiting to avoid overwhelming the system
  - Proper error handling and telemetry
  """

  use Broadway
  require Logger

  alias Broadway.Message
  alias Reencodarr.AbAv1
  alias Reencodarr.CrfSearcher.Broadway.Producer

  @typedoc "Video struct for CRF search processing"
  @type video :: %{id: integer(), path: binary()}

  @typedoc "Broadway pipeline configuration"
  @type config :: keyword()

  # Configuration constants
  @default_config [
    rate_limit_messages: 10,
    rate_limit_interval: 1_000,
    batch_size: 1,
    batch_timeout: 5_000,
    crf_quality: 95
  ]

  @doc """
  Start the Broadway pipeline with configurable options.

  ## Options
    * `:rate_limit_messages` - Number of messages allowed per interval (default: 10)
    * `:rate_limit_interval` - Rate limit interval in milliseconds (default: 1000)
    * `:batch_size` - Number of messages per batch (default: 1)
    * `:batch_timeout` - Batch timeout in milliseconds (default: 5000)
    * `:crf_quality` - CRF quality setting (default: 95)

  ## Examples
      iex> Reencodarr.CrfSearcher.Broadway.start_link([])
      {:ok, pid}

      iex> Reencodarr.CrfSearcher.Broadway.start_link([rate_limit_messages: 5])
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
          # Use normal rate limiting - pause/resume controlled by producer state
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
        crf_quality: config[:crf_quality],
        rate_limit_messages: config[:rate_limit_messages],
        rate_limit_interval: config[:rate_limit_interval]
      }
    )
  end

  @doc """
  Check if the CRF searcher pipeline is running.
  """
  @spec running?() :: boolean()
  def running? do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  @doc """
  Pause by stopping the Broadway pipeline.
  """
  @spec pause() :: :ok
  def pause do
    Logger.info("[CRF Searcher] Stopping Broadway pipeline")
    Reencodarr.CrfSearcher.Supervisor.stop_broadway()
    :ok
  end

  @doc """
  Resume by starting the Broadway pipeline.
  """
  @spec resume() :: :ok
  def resume do
    Logger.info("[CRF Searcher] Starting Broadway pipeline")

    case Reencodarr.CrfSearcher.Supervisor.start_broadway() do
      {:ok, _pid} -> :ok
      {:error, :already_started} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc "Alias for resume"
  @spec start() :: :ok
  def start, do: resume()

  # Broadway callbacks

  @impl Broadway
  def handle_message(_processor_name, message, _context) do
    # Messages are processed in batches, so we just pass them through
    message
  end

  @impl Broadway
  def handle_batch(_batcher, messages, _batch_info, _context) do
    Logger.info("[CRF Broadway] Processing batch of #{length(messages)} videos")

    Enum.map(messages, fn message ->
      # Use adaptive VMAF target based on file size
      vmaf_target = Reencodarr.Rules.vmaf_target(message.data)

      Logger.info(
        "[CRF Broadway] Processing video #{message.data.id}: #{Path.basename(message.data.path)} (VMAF target: #{vmaf_target})"
      )

      case process_video_crf_search(message.data, vmaf_target) do
        :ok ->
          Logger.info("[CRF Broadway] Successfully queued video #{message.data.id}")
          message

        {:error, reason} ->
          Logger.warning("CRF search failed for video #{inspect(message.data)}: #{reason}")
          Message.failed(message, reason)
      end
    end)
  end

  @doc """
  Transform raw video data into a Broadway message.

  This function is called by the Broadway producer to transform
  events into messages that can be processed by the pipeline.
  """
  @spec transform(video(), keyword()) :: Message.t()
  def transform(video, _opts) do
    %Message{
      data: video,
      acknowledger: Broadway.NoopAcknowledger.init()
    }
  end

  # Private functions

  @spec process_video_crf_search(video(), pos_integer()) :: :ok | {:error, term()}
  defp process_video_crf_search(video, crf_quality) do
    Logger.info(
      "[CRF Broadway] Starting CRF search for video #{video.id}: #{Path.basename(video.path)}"
    )

    # Just send to CrfSearch - it's fire-and-forget via cast
    # CrfSearch will handle state transitions when it actually starts processing
    result = AbAv1.crf_search(video, crf_quality)

    Logger.info(
      "[CRF Broadway] CRF search queued for video #{video.id}, result: #{inspect(result)}"
    )

    :ok
  rescue
    exception ->
      error_message =
        "Exception during CRF search for video #{video.id}: #{Exception.message(exception)}"

      Logger.error(error_message)

      {:error, error_message}
  end
end
