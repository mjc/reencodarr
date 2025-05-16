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
    @enforce_keys []
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
      :encode_queue_length,
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

    stats = build_stats()

    state = %{stats: stats}

    :timer.send_interval(@broadcast_interval, :broadcast_stats)
    {:ok, state}
  end

  @impl true
  def handle_info({:crf_search_progress, %{filename: :none}}, state) do
    stats = %{state.stats | crf_search_progress: %CrfSearchProgress{}}
    %{state | stats: stats} |> broadcast_stats_and_reply()
  end

  def handle_info({:crf_search_progress, vmaf}, state) do
    new_crf_search_progress = update_progress(state.stats.crf_search_progress, vmaf)
    stats = %{state.stats | crf_search_progress: new_crf_search_progress}
    %{state | stats: stats} |> broadcast_stats_and_reply()
  end

  def handle_info({:encoding, %{percent: percent, eta: eta, fps: fps}}, state) do
    new_encoding_progress =
      update_progress(state.stats.encoding_progress, %EncodingProgress{
        percent: percent,
        eta: eta,
        fps: fps
      })
    stats = %{state.stats | encoding_progress: new_encoding_progress}
    %{state | stats: stats} |> broadcast_stats_and_reply()
  end

  def handle_info({:encoder, :started, filename}, state) do
    new_encoding_progress =
      update_progress(state.stats.encoding_progress, %EncodingProgress{filename: filename})
    stats = %{state.stats | encoding: true, encoding_progress: new_encoding_progress}
    %{state | stats: stats} |> broadcast_stats_and_reply()
  end

  def handle_info({:encoder, :paused}, state) do
    stats = %{state.stats | encoding: false}
    %{state | stats: stats} |> broadcast_stats_and_reply()
  end

  def handle_info({:encoder, :none}, state) do
    stats = %{state.stats | encoding_progress: %EncodingProgress{}}
    %{state | stats: stats} |> broadcast_stats_and_reply()
  end

  def handle_info({:sync_progress, progress}, state) do
    stats = %{state.stats | sync_progress: progress}
    %{state | stats: stats} |> broadcast_stats_and_reply()
  end

  def handle_info(:sync_complete, state) do
    stats = build_stats() |> Map.put(:syncing, false) |> Map.put(:sync_progress, 0)
    %{state | stats: stats} |> broadcast_stats_and_reply()
  end

  def handle_info({:crf_searcher, :started}, state) do
    stats = %{state.stats | crf_searching: true}
    %{state | stats: stats} |> broadcast_stats_and_reply()
  end

  def handle_info({:crf_searcher, :paused}, state) do
    stats = %{state.stats | crf_searching: false}
    %{state | stats: stats} |> broadcast_stats_and_reply()
  end

  def handle_info({:video_upserted, _video}, state) do
    stats = build_stats()
    %{state | stats: stats} |> broadcast_stats_and_reply()
  end

  def handle_info({:vmaf_upserted, _vmaf}, state) do
    stats = build_stats()
    %{state | stats: stats} |> broadcast_stats_and_reply()
  end

  @impl true
  def handle_info(:broadcast_stats, state) do
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, state.stats})
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    {:reply, state.stats, state}
  end

  @impl true
  def handle_call({:get_progress, key}, _from, state) do
    {:reply, Map.get(state.stats, key), state}
  end

  # --- Private Helpers ---

  defp subscribe_to_topics do
    for topic <- ["progress", "encoder", "crf_searcher", "media_events"] do
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, topic)
    end
  end

  defp broadcast_stats_and_reply(state) do
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, state.stats})
    {:noreply, state}
  end

  @spec update_progress(struct(), struct()) :: struct()
  defp update_progress(current, incoming) when is_map(current) and is_map(incoming) do
    defaults = struct(current.__struct__)

    incoming
    |> Map.from_struct()
    |> Enum.reject(fn {key, new} -> new == Map.get(defaults, key) end)
    |> Enum.into(%{})
    |> then(&struct(current, &1))
  end

  defp build_stats do
    media_stats = Media.fetch_stats()
    %Stats{
      total_videos: media_stats.total_videos,
      reencoded: media_stats.reencoded,
      not_reencoded: media_stats.not_reencoded,
      queue_length: media_stats.queue_length,
      most_recent_video_update: media_stats.most_recent_video_update,
      most_recent_inserted_video: media_stats.most_recent_inserted_video,
      total_vmafs: media_stats.total_vmafs,
      chosen_vmafs_count: media_stats.chosen_vmafs_count,
      lowest_vmaf: media_stats.lowest_vmaf,
      encoding: Encoder.scanning?(),
      crf_searching: CrfSearcher.scanning?(),
      encoding_progress: %EncodingProgress{},
      crf_search_progress: %CrfSearchProgress{},
      syncing: false,
      sync_progress: 0
    }
  end
end
