defmodule Reencodarr.Statistics do
  use GenServer
  alias Reencodarr.{Media, Encoder, CrfSearcher}

  require Logger

  defmodule EncodingProgress do
    defstruct filename: :none, percent: 0, eta: 0, fps: 0
  end

  defmodule CrfSearchProgress do
    defstruct filename: :none, percent: 0, eta: 0, fps: 0, crf: 0, score: 0
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "progress")
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "encoder")
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "crf_searcher")
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "media_events")

    # Only keep real-time progress in state, not full stats
    initial_state = %{
      encoding: Encoder.scanning?(),
      crf_searching: CrfSearcher.scanning?(),
      syncing: false,
      sync_progress: 0,
      crf_search_progress: %CrfSearchProgress{},
      encoding_progress: %EncodingProgress{}
    }

    {:ok, initial_state}
  end

  # Keep only real-time progress updates in state and broadcast as before
  @impl true
  def handle_info({:crf_search_progress, %{filename: :none}}, state) do
    new_state = %{state | crf_search_progress: %CrfSearchProgress{}}
    Logger.debug("CRF search progress reset")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, new_state})
    {:noreply, new_state}
  end

  def handle_info({:crf_search_progress, vmaf}, state) do
    new_crf_search_progress = update_progress(state.crf_search_progress, vmaf)
    new_state = %{state | crf_search_progress: new_crf_search_progress}
    Logger.debug("Received progress: #{inspect(vmaf)}")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, new_state})
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:encoding, %{percent: percent, eta: eta, fps: fps}}, state) do
    new_encoding_progress =
      update_progress(state.encoding_progress, %EncodingProgress{
        percent: percent,
        eta: eta,
        fps: fps
      })

    new_state = %{state | encoding_progress: new_encoding_progress}

    Logger.info("Encoding progress: #{percent}% ETA: #{eta} FPS: #{fps}")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, new_state})
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:encoder, :started, filename}, state) do
    new_encoding_progress =
      update_progress(state.encoding_progress, %EncodingProgress{filename: filename})

    new_state = %{
      state
      | encoding: true,
        encoding_progress: new_encoding_progress
    }

    Logger.debug("Encoder started for file: #{filename}")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, new_state})
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:encoder, :paused}, state) do
    new_state = %{state | encoding: false}
    Logger.debug("Encoder paused")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, new_state})
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:encoder, :none}, state) do
    new_encoding_progress =
      update_progress(state.encoding_progress, %EncodingProgress{filename: :none})

    new_state = %{
      state
      | encoding_progress: new_encoding_progress
    }

    Logger.debug("No encoding progress to update")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, new_state})
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:sync_progress, progress}, state) do
    new_state = %{state | sync_progress: progress}
    Logger.debug("Sync progress: #{inspect(progress)}")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, new_state})
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:sync_complete, state) do
    new_state = %{state | syncing: false, sync_progress: 0}
    Logger.info("Sync complete")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, new_state})
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:crf_searcher, :started}, state) do
    new_state = %{state | crf_searching: true}
    Logger.debug("CRF searcher started")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, new_state})
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:crf_searcher, :paused}, state) do
    new_state = %{state | crf_searching: false}
    Logger.debug("CRF searcher paused")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, new_state})
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:video_upserted, _video}, state) do
    Logger.debug("Video upserted.")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, state})
    {:noreply, state}
  end

  def handle_info({:vmaf_upserted, _vmaf}, state) do
    Logger.debug("VMAF upserted.")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, state})
    {:noreply, state}
  end

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

  # Helper functions to get current progress from GenServer state
  defp get_encoding_progress do
    GenServer.call(__MODULE__, {:get_progress, :encoding_progress})
  end

  defp get_crf_search_progress do
    GenServer.call(__MODULE__, {:get_progress, :crf_search_progress})
  end

  defp get_syncing do
    GenServer.call(__MODULE__, {:get_progress, :syncing})
  end

  defp get_sync_progress do
    GenServer.call(__MODULE__, {:get_progress, :sync_progress})
  end

  @impl true
  def handle_call({:get_progress, key}, _from, state) do
    {:reply, Map.get(state, key), state}
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
end
