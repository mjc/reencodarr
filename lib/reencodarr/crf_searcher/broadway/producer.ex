defmodule Reencodarr.CrfSearcher.Broadway.Producer do
  @moduledoc """
  Broadway producer for CRF search - just returns videos one at a time.
  CrfSearch GenServer handles queueing via its mailbox.
  """

  use GenStage
  require Logger

  alias Reencodarr.Media

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenStage
  def init(_opts) do
    {:producer, %{}}
  end

  @impl GenStage
  def handle_demand(_demand, state) do
    # Just return 1 video per demand - CrfSearch will handle queueing
    videos = Media.get_videos_for_crf_search(1)
    {:noreply, videos, state}
  end

  @impl GenStage
  def handle_info(_msg, state), do: {:noreply, [], state}

  @impl GenStage
  def handle_cast(_msg, state), do: {:noreply, [], state}

  @impl GenStage
  def handle_call(_msg, _from, state), do: {:reply, :ok, [], state}
end
