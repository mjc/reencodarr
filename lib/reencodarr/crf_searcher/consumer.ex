defmodule Reencodarr.CrfSearcher.Consumer do
  use GenStage
  require Logger

  alias Reencodarr.AbAv1

  def start_link() do
    GenStage.start_link(__MODULE__, :ok)
  end

  @impl true
  def init(:ok) do
    {:consumer, :ok, subscribe_to: [{Reencodarr.CrfSearcher.Producer, max_demand: 5}]}
  end

  @impl true
  def handle_events(videos, _from, state) do
    for video <- videos do
      Task.Supervisor.start_child(Reencodarr.TaskSupervisor, fn ->
        try do
          Logger.info("Starting CRF search for #{video.path}")
          AbAv1.crf_search(video)
        rescue
          e ->
            Logger.error("CRF search failed for #{video.path}: #{inspect(e)}")
            # Optionally mark video as failed or retry logic here
        end
      end)
    end

    {:noreply, [], state}
  end
end
