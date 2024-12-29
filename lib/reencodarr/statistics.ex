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

  @update_interval 5_000

  def start_link(_) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "progress")
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "encoder")
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "crf_searcher")
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "media_events") # Subscribe to media_events instead of stats

    initial_state = %{
      stats: Media.fetch_stats(),
      encoding: Encoder.scanning?(),
      crf_searching: CrfSearcher.scanning?(),
      syncing: false,
      sync_progress: 0,
      crf_search_progress: %CrfSearchProgress{},
      encoding_progress: %EncodingProgress{}
    }

    schedule_update()
    {:ok, initial_state}
  end

  @impl true
  def handle_info(:update_stats, state) do
    new_stats = fetch_all_stats(state)
    Logger.debug("Updating stats: #{inspect(new_stats)}")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, new_stats})
    schedule_update()
    {:noreply, new_stats}
  end

  @impl true
  def handle_info({:crf_search_progress, %{filename: :none}}, state) do
    new_state = %{state | crf_search_progress: %CrfSearchProgress{}}
    Logger.debug("CRF search progress reset")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, new_state})
    {:noreply, new_state}
  end

  def handle_info({:crf_search_progress, vmaf}, state) do
    new_crf_search_progress = update_crf_search_progress(state.crf_search_progress, vmaf)
    new_state = %{state | crf_search_progress: new_crf_search_progress}
    Logger.debug("Received progress: #{inspect(vmaf)}")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, new_state})
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:encoding, %{percent: percent, eta: eta, fps: fps}}, state) do
    new_state = %{
      state
      | encoding_progress: %EncodingProgress{
          state.encoding_progress
          | percent: percent,
            eta: eta,
            fps: fps
        }
    }

    Logger.info("Encoding progress: #{percent}% ETA: #{eta} FPS: #{fps}")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, new_state})
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:encoder, :started, filename}, state) do
    new_state = %{
      state
      | encoding: true,
        encoding_progress: %EncodingProgress{state.encoding_progress | filename: filename}
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
    new_state = %{
      state
      | encoding_progress: %EncodingProgress{state.encoding_progress | filename: :none}
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
    new_stats = Media.fetch_stats()
    Logger.debug("Video upserted. Updating stats.")
    new_state = %{state | stats: new_stats}
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, new_state})
    {:noreply, new_state}
  end

  def handle_info({:vmaf_upserted, _vmaf}, state) do
    new_stats = Media.fetch_stats()
    Logger.debug("VMAF upserted. Updating stats.")
    new_state = %{state | stats: new_stats}
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, new_state})
    {:noreply, new_state}
  end

  defp schedule_update do
    Process.send_after(self(), :update_stats, @update_interval)
  end

  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    {:reply, state, state}
  end

  defp fetch_all_stats(state) do
    new_stats = %{
      stats: Media.fetch_stats(),
      encoding: Encoder.scanning?(),
      crf_searching: CrfSearcher.scanning?(),
      # Ensure encoding_progress is included
      encoding_progress: state.encoding_progress,
      crf_search_progress: state.crf_search_progress
    }

    Map.merge(state, new_stats)
  end

  defp update_crf_search_progress(current, incoming) do
    %CrfSearchProgress{
      filename: update_field(current.filename, incoming.filename, :none),
      percent: update_field(current.percent, incoming.percent, 0),
      eta: update_field(current.eta, incoming.eta, 0),
      fps: update_field(current.fps, incoming.fps, 0),
      crf: update_field(current.crf, incoming.crf, 0),
      score: update_field(current.score, incoming.score, 0)
    }
  end

  defp update_field(_current, incoming, default) when incoming != default, do: incoming
  defp update_field(current, _incoming, _default), do: current
end
