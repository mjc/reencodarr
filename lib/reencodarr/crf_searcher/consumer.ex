defmodule Reencodarr.CrfSearcher.Consumer do
  use GenStage
  require Logger

  alias Reencodarr.AbAv1

  def start_link() do
    GenStage.start_link(__MODULE__, :ok)
  end

  @impl true
  def init(:ok) do
    {:consumer, :ok, subscribe_to: [{Reencodarr.CrfSearcher.Producer, max_demand: 1}]}
  end

  @impl true
  def handle_events(videos, _from, state) do
    for video <- videos do
      try do
        Logger.info("Starting CRF search for #{video.path}")
        AbAv1.crf_search(video)

        # Block until CRF search is actually complete
        wait_for_crf_search_completion()

        Logger.info("Completed CRF search for #{video.path}")
      rescue
        e ->
          Logger.error("CRF search failed for #{video.path}: #{inspect(e)}")
          # Optionally mark video as failed or retry logic here
      end
    end

    {:noreply, [], state}
  end

  # Poll the CRF search status until it's no longer running
  defp wait_for_crf_search_completion() do
    case GenServer.call(Reencodarr.AbAv1.CrfSearch, :running?) do
      :running ->
        # Still running, wait a bit and check again
        Process.sleep(100)
        wait_for_crf_search_completion()
      :not_running ->
        # CRF search is complete
        :ok
    end
  end
end
