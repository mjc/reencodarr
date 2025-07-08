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

  alias Reencodarr.AbAv1
  alias Broadway.Message

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
        module: {Reencodarr.CrfSearcher.Broadway.Producer, []},
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
      context: %{crf_quality: config[:crf_quality]}
    )
  end

  @doc """
  Add a video to the pipeline for CRF search processing.

  ## Parameters
    * `video` - Video struct containing id and path

  ## Examples
      iex> video = %{id: 1, path: "/path/to/video.mp4"}
      iex> Reencodarr.CrfSearcher.Broadway.process_video(video)
      :ok
  """
  @spec process_video(video()) :: :ok | {:error, term()}
  def process_video(video) do
    case Reencodarr.CrfSearcher.Broadway.Producer.add_video(video) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Check if the CRF searcher pipeline is running (not paused).

  ## Examples
      iex> Reencodarr.CrfSearcher.Broadway.running?()
      true
  """
  @spec running?() :: boolean()
  def running? do
    with pid when is_pid(pid) <- Process.whereis(__MODULE__),
         true <- Process.alive?(pid) do
      Reencodarr.CrfSearcher.Broadway.Producer.running?()
    else
      _ -> false
    end
  end

  @doc """
  Pause the CRF searcher pipeline.

  ## Examples
      iex> Reencodarr.CrfSearcher.Broadway.pause()
      :ok
  """
  @spec pause() :: :ok | {:error, term()}
  def pause do
    Reencodarr.CrfSearcher.Broadway.Producer.pause()
  end

  @doc """
  Resume the CRF searcher pipeline.

  ## Examples
      iex> Reencodarr.CrfSearcher.Broadway.resume()
      :ok
  """
  @spec resume() :: :ok | {:error, term()}
  def resume do
    Reencodarr.CrfSearcher.Broadway.Producer.resume()
  end

  @doc """
  Start the CRF searcher pipeline.

  Alias for `resume/0` to maintain API compatibility.
  """
  @spec start() :: :ok | {:error, term()}
  def start, do: resume()

  # Broadway callbacks

  @impl Broadway
  def handle_message(_processor_name, message, _context) do
    # Messages are processed in batches, so we just pass them through
    message
  end

  @impl Broadway
  def handle_batch(:default, messages, _batch_info, context) do
    crf_quality = Map.get(context, :crf_quality, 95)

    Enum.map(messages, fn message ->
      case process_video_crf_search(message.data, crf_quality) do
        :ok ->
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
    Logger.info("Starting CRF search for video #{video.id}: #{video.path}")

    # Emit telemetry event for monitoring
    :telemetry.execute(
      [:reencodarr, :crf_search, :start],
      %{},
      %{video_id: video.id, video_path: video.path}
    )

    # AbAv1.crf_search/2 always returns :ok since it's a GenServer.cast
    # The actual success/failure is handled by the GenServer
    :ok = AbAv1.crf_search(video, crf_quality)

    Logger.debug("CRF search queued successfully for video #{video.id}")

    :telemetry.execute(
      [:reencodarr, :crf_search, :success],
      %{},
      %{video_id: video.id}
    )

    :ok
  rescue
    exception ->
      error_message =
        "Exception during CRF search for video #{video.id}: #{Exception.message(exception)}"

      Logger.error(error_message)

      :telemetry.execute(
        [:reencodarr, :crf_search, :exception],
        %{},
        %{video_id: video.id, exception: exception}
      )

      {:error, error_message}
  end
end
