defmodule Reencodarr.Statistics do
  use GenServer
  alias Reencodarr.{Media, Encoder, CrfSearcher}
  require Logger

  @broadcast_interval 5_000

  # --- Structs ---

  defmodule EncodingProgress do
    @enforce_keys []
    defstruct filename: :none, percent: 0, eta: 0, fps: 0
  end

  defmodule CrfSearchProgress do
    @enforce_keys []
    defstruct filename: :none, percent: 0, eta: 0, fps: 0, crf: 0, score: 0
  end

  defmodule Stats do
    defstruct [
      :not_reencoded,
      :reencoded,
      :total_videos,
      :avg_vmaf_percentage,
      :total_vmafs,
      :chosen_vmafs_count,
      :lowest_vmaf,
      :lowest_vmaf_by_time,
      :most_recent_video_update,
      :most_recent_inserted_video,
      :queue_length,
      :encode_queue_length
    ]
  end

  defmodule State do
    defstruct [
      :stats,
      :encoding,
      :crf_searching,
      :encoding_progress,
      :crf_search_progress,
      :syncing,
      :sync_progress
    ]
  end

  # --- Public API ---

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(:ok) do
    subscribe_to_topics()

    # Use safe defaults; fetch risky data in handle_continue
    state = %State{
      stats: %Stats{},
      encoding: false,
      crf_searching: false,
      syncing: false,
      sync_progress: 0,
      crf_search_progress: %CrfSearchProgress{},
      encoding_progress: %EncodingProgress{}
    }

    :timer.send_interval(@broadcast_interval, :broadcast_stats)
    {:ok, state, {:continue, :fetch_stats}}
  end

  @impl true
  def handle_continue(:fetch_stats, state) do
    stats = Media.fetch_stats()
    encoding = Encoder.scanning?()
    crf_searching = CrfSearcher.scanning?()

    new_state = %State{
      state |
      stats: stats,
      encoding: encoding,
      crf_searching: crf_searching
    }
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:crf_search_progress, %CrfSearchProgress{} = progress}, state) do
    %{state | crf_search_progress: progress}
    |> broadcast_stats_and_reply()
  end

  def handle_info({:crf_search_progress, %{filename: :none}}, state) do
    %{state | crf_search_progress: %CrfSearchProgress{}}
    |> broadcast_stats_and_reply()
  end

  def handle_info({:encoding, %EncodingProgress{} = progress}, state) do
    %{state | encoding_progress: progress}
    |> broadcast_stats_and_reply()
  end

  def handle_info({:encoding, %{percent: percent, eta: eta, fps: fps}}, state) do
    progress = %EncodingProgress{percent: percent, eta: eta, fps: fps}
    %{state | encoding_progress: progress}
    |> broadcast_stats_and_reply()
  end

  def handle_info({:encoder, :started, filename}, state) do
    progress = %EncodingProgress{filename: filename}
    %{state | encoding: true, encoding_progress: progress}
    |> broadcast_stats_and_reply()
  end

  def handle_info({:encoder, :paused}, state) do
    %{state | encoding: false}
    |> broadcast_stats_and_reply()
  end

  def handle_info({:encoder, :none}, state) do
    %{state | encoding_progress: %EncodingProgress{}}
    |> broadcast_stats_and_reply()
  end

  def handle_info({:sync_progress, progress}, state) do
    %{state | sync_progress: progress}
    |> broadcast_stats_and_reply()
  end

  def handle_info(:sync_complete, state) do
    # Sync complete, refresh stats
    stats = Media.fetch_stats()

    %{state | syncing: false, sync_progress: 0, stats: stats}
    |> broadcast_stats_and_reply()
  end

  def handle_info({:crf_searcher, :started}, state) do
    %{state | crf_searching: true}
    |> broadcast_stats_and_reply()
  end

  def handle_info({:crf_searcher, :paused}, state) do
    %{state | crf_searching: false}
    |> broadcast_stats_and_reply()
  end

  def handle_info({:video_upserted, _video}, state) do
    stats = Media.fetch_stats()

    %{state | stats: stats}
    |> broadcast_stats_and_reply()
  end

  def handle_info({:vmaf_upserted, _vmaf}, state) do
    stats = Media.fetch_stats()

    %{state | stats: stats}
    |> broadcast_stats_and_reply()
  end

  @impl true
  def handle_info(:broadcast_stats, state) do
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, state})
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:get_progress, key}, _from, state) do
    {:reply, Map.get(state, key), state}
  end

  # --- Private Helpers ---

  defp subscribe_to_topics do
    for topic <- ["progress", "encoder", "crf_searcher", "media_events"] do
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, topic)
    end
  end

  defp broadcast_stats_and_reply(state) do
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, state})
    {:noreply, state}
  end
end
