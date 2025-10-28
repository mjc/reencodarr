defmodule Reencodarr.CrfSearcher.Broadway.Producer do
  @moduledoc """
  Simplest possible Broadway producer for CRF search.
  When demand arrives, check if CrfSearch is available and return 1 video if so.
  """

  use GenStage
  require Logger

  alias Reencodarr.AbAv1.CrfSearch
  alias Reencodarr.Media

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenStage
  def init(_opts) do
    # Poll every 2 seconds to check for new work
    schedule_poll()
    {:producer, %{}}
  end

  @impl GenStage
  def handle_demand(_demand, state) do
    dispatch(state)
  end

  @impl GenStage
  def handle_info(:poll, state) do
    schedule_poll()
    # Check if there's work and CrfSearch is available, wake up Broadway if so
    if CrfSearch.available?() do
      case Media.get_videos_for_crf_search(1) do
        [] -> {:noreply, [], state}
        videos -> {:noreply, videos, state}
      end
    else
      {:noreply, [], state}
    end
  end

  @impl GenStage
  def handle_info(_msg, state), do: {:noreply, [], state}

  defp dispatch(state) do
    if CrfSearch.available?() do
      videos = Media.get_videos_for_crf_search(1)
      {:noreply, videos, state}
    else
      {:noreply, [], state}
    end
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, 2000)
  end
end
