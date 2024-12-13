defmodule Reencodarr.Statistics do
  use GenServer
  alias Reencodarr.{Media, Encoder, CrfSearcher}

  @update_interval 5_000

  def start_link(_) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def init(:ok) do
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "progress")

    initial_state = %{
      stats: Media.fetch_stats(),
      encoding: Encoder.scanning?(),
      crf_searching: CrfSearcher.scanning?(),
      syncing: false,
      sync_progress: 0,
      crf_search_progress: %Media.Vmaf{}
    }

    schedule_update()
    {:ok, initial_state}
  end

  def handle_info(:update_stats, state) do
    new_stats = fetch_all_stats(state)
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, new_stats})
    schedule_update()
    {:noreply, new_stats}
  end

  def handle_info({:progress, vmaf}, state) do
    new_state = Map.put(state, :crf_search_progress, vmaf)
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, new_state})
    {:noreply, new_state}
  end

  defp schedule_update do
    Process.send_after(self(), :update_stats, @update_interval)
  end

  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  def handle_call(:get_stats, _from, state) do
    {:reply, state, state}
  end

  defp fetch_all_stats(state) do
    new_stats = %{
      stats: Media.fetch_stats(),
      encoding: Encoder.scanning?(),
      crf_searching: CrfSearcher.scanning?()
    }

    Map.merge(state, new_stats)
  end
end
