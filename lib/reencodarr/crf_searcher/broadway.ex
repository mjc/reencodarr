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
  alias Reencodarr.AbAv1.CrfSearch
  alias Reencodarr.CrfSearcher.Broadway.Producer
  alias Reencodarr.Media

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
    case Producer.add_video(video) do
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
      Producer.running?()
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
    Producer.pause()
  end

  @doc """
  Resume the CRF searcher pipeline.

  ## Examples
      iex> Reencodarr.CrfSearcher.Broadway.resume()
      :ok
  """
  @spec resume() :: :ok | {:error, term()}
  def resume do
    Producer.resume()
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
  def handle_batch(:default, messages, _batch_info, _context) do
    result =
      Enum.map(messages, fn message ->
        # Determine VMAF target based on video bitrate
        crf_quality = determine_vmaf_target(message.data)

        case process_video_crf_search(message.data, crf_quality) do
          :ok ->
            message

          {:error, error} ->
            Logger.warning(
              "⚠️ CRF Searcher: Failed to process video #{message.data.id}: #{inspect(error)}"
            )

            Message.failed(message, error)
        end
      end)

    # CRITICAL: Notify producer that batch processing is complete and ready for next demand
    Producer.dispatch_available()

    result
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

  # Determines the VMAF target based on video runtime.
  # VMAF target determination based on bitrate:
  # - Videos with bitrate above 40mbit: VMAF 90
  # - Videos with bitrate above 25mbit: VMAF 92
  # - Videos with bitrate above 15mbit: VMAF 93
  # - All other videos (below 15mbit): VMAF 95
  defp determine_vmaf_target(%{bitrate: bitrate}) when is_number(bitrate) do
    bitrate_mbps = bitrate / 1_000_000

    cond do
      bitrate_mbps > 40 -> 90
      bitrate_mbps > 25 -> 92
      bitrate_mbps > 15 -> 93
      true -> 95
    end
  end

  # Fallback for when bitrate is not available
  defp determine_vmaf_target(_video) do
    # Default to higher quality when bitrate unknown
    95
  end

  @spec process_video_crf_search(video(), pos_integer()) :: :ok | {:error, term()}
  defp process_video_crf_search(video, vmaf_target) do
    # CRITICAL: Update video state BEFORE starting CRF search to prevent infinite loop
    case Media.update_video_status(video, %{"state" => "crf_searching"}) do
      {:ok, updated_video} ->
        case CrfSearch.crf_search(updated_video, vmaf_target) do
          :ok ->
            :ok

          error ->
            {:error, error}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception ->
      {:error, exception}
  end
end
