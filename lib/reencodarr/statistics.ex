defmodule Reencodarr.Statistics do
  use GenServer
  alias Reencodarr.{Media, Encoder, CrfSearcher}
  alias Reencodarr.Statistics.{EncodingProgress, CrfSearchProgress, Stats, State}
  require Logger

  @broadcast_interval 5_000

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
      crf_search_progress: %CrfSearchProgress{
        filename: :none, percent: 0, eta: 0, fps: 0, crf: 0, score: 0
      },
      encoding_progress: %EncodingProgress{
        filename: :none, percent: 0, eta: 0, fps: 0
      }
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
      state
      | stats: stats,
        encoding: encoding,
        crf_searching: crf_searching
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:crf_search_progress, %CrfSearchProgress{} = progress}, %State{} = state) do
    broadcast_stats_and_reply(%State{state | crf_search_progress: progress})
  end

  def handle_info({:crf_search_progress, %{filename: :none}}, %State{} = state) do
    broadcast_stats_and_reply(%State{state | crf_search_progress: %CrfSearchProgress{}})
  end

  def handle_info({:encoding, %EncodingProgress{} = progress}, %State{} = state) do
    broadcast_stats_and_reply(%State{state | encoding_progress: progress})
  end

  def handle_info({:encoding, %{percent: percent, eta: eta, fps: fps}}, %State{} = state) do
    progress = %EncodingProgress{filename: :none, percent: percent, eta: eta, fps: fps}
    broadcast_stats_and_reply(%State{state | encoding_progress: progress})
  end

  def handle_info({:encoder, :started, filename}, %State{} = state) do
    progress = %EncodingProgress{filename: filename, percent: 0, eta: 0, fps: 0}
    broadcast_stats_and_reply(%State{state | encoding: true, encoding_progress: progress})
  end

  def handle_info({:encoder, :paused}, %State{} = state) do
    broadcast_stats_and_reply(%State{state | encoding: false})
  end

  def handle_info({:encoder, :none}, %State{} = state) do
    broadcast_stats_and_reply(%State{state | encoding_progress: %EncodingProgress{filename: :none, percent: 0, eta: 0, fps: 0}})
  end

  def handle_info({:sync_progress, progress}, %State{} = state) do
    broadcast_stats_and_reply(%State{state | sync_progress: progress})
  end

  def handle_info(:sync_complete, %State{} = state) do
    stats = Media.fetch_stats()
    broadcast_stats_and_reply(%State{state | syncing: false, sync_progress: 0, stats: stats})
  end

  def handle_info({:crf_searcher, :started}, %State{} = state) do
    broadcast_stats_and_reply(%State{state | crf_searching: true})
  end

  def handle_info({:crf_searcher, :paused}, %State{} = state) do
    broadcast_stats_and_reply(%State{state | crf_searching: false})
  end

  def handle_info({:video_upserted, _video}, %State{} = state) do
    stats = Media.fetch_stats()
    broadcast_stats_and_reply(%State{state | stats: stats})
  end

  def handle_info({:vmaf_upserted, _vmaf}, %State{} = state) do
    stats = Media.fetch_stats()
    broadcast_stats_and_reply(%State{state | stats: stats})
  end

  @impl true
  def handle_info(:broadcast_stats, %State{} = state) do
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, state})
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_stats, _from, %State{} = state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:get_progress, key}, _from, %State{} = state) do
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
