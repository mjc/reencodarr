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

  # --- Public API ---

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def get_stats do
    %{
      stats: Media.fetch_stats(),
      encoding: Encoder.scanning?(),
      crf_searching: CrfSearcher.scanning?(),
      encoding_progress: get_encoding_progress(),
      crf_search_progress: get_crf_search_progress(),
      syncing: get_syncing(),
      sync_progress: get_sync_progress()
    }
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(:ok) do
    subscribe_to_topics()

    state = %{
      encoding: Encoder.scanning?(),
      crf_searching: CrfSearcher.scanning?(),
      syncing: false,
      sync_progress: 0,
      crf_search_progress: %CrfSearchProgress{},
      encoding_progress: %EncodingProgress{}
    }

    :timer.send_interval(@broadcast_interval, :broadcast_stats)
    {:ok, state}
  end

  @impl true
  def handle_info({:crf_search_progress, %{filename: :none}}, state) do
    state
    |> Map.put(:crf_search_progress, %CrfSearchProgress{})
    |> broadcast_stats_and_reply()
  end

  def handle_info({:crf_search_progress, vmaf}, state) do
    new_crf_search_progress = update_progress(state.crf_search_progress, vmaf)

    %{state | crf_search_progress: new_crf_search_progress}
    |> broadcast_stats_and_reply()
  end

  def handle_info({:encoding, %{percent: percent, eta: eta, fps: fps}}, state) do
    new_encoding_progress =
      update_progress(state.encoding_progress, %EncodingProgress{
        percent: percent,
        eta: eta,
        fps: fps
      })

    %{state | encoding_progress: new_encoding_progress}
    |> broadcast_stats_and_reply()
  end

  def handle_info({:encoder, :started, filename}, state) do
    new_encoding_progress =
      update_progress(state.encoding_progress, %EncodingProgress{filename: filename})

    %{state | encoding: true, encoding_progress: new_encoding_progress}
    |> broadcast_stats_and_reply()
  end

  def handle_info({:encoder, :paused}, state) do
    %{state | encoding: false}
    |> broadcast_stats_and_reply()
  end

  def handle_info({:encoder, :none}, state) do
    new_encoding_progress =
      update_progress(state.encoding_progress, %EncodingProgress{filename: :none})

    %{state | encoding_progress: new_encoding_progress}
    |> broadcast_stats_and_reply()
  end

  def handle_info({:sync_progress, progress}, state) do
    %{state | sync_progress: progress}
    |> broadcast_stats_and_reply()
  end

  def handle_info(:sync_complete, state) do
    %{state | syncing: false, sync_progress: 0}
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

  def handle_info({:video_upserted, _video}, state), do: broadcast_stats_and_reply(state)
  def handle_info({:vmaf_upserted, _vmaf}, state), do: broadcast_stats_and_reply(state)

  @impl true
  def handle_info(:broadcast_stats, state) do
    stats = %{
      encoding: state.encoding,
      crf_searching: state.crf_searching,
      syncing: state.syncing,
      sync_progress: state.sync_progress,
      crf_search_progress: state.crf_search_progress,
      encoding_progress: state.encoding_progress
    }

    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, stats})
    {:noreply, state}
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

  defp get_encoding_progress, do: GenServer.call(__MODULE__, {:get_progress, :encoding_progress})

  defp get_crf_search_progress,
    do: GenServer.call(__MODULE__, {:get_progress, :crf_search_progress})

  defp get_syncing, do: GenServer.call(__MODULE__, {:get_progress, :syncing})
  defp get_sync_progress, do: GenServer.call(__MODULE__, {:get_progress, :sync_progress})

  @spec update_progress(struct(), struct()) :: struct()
  defp update_progress(current, incoming) when is_map(current) and is_map(incoming) do
    defaults = struct(current.__struct__)

    incoming
    |> Map.from_struct()
    |> Enum.reject(fn {key, new} -> new == Map.get(defaults, key) end)
    |> Enum.into(%{})
    |> then(&struct(current, &1))
  end
end
