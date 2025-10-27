defmodule Reencodarr.CrfSearcher.Broadway.Producer do
  @moduledoc """
  Broadway producer for CRF search - just returns videos one at a time.
  CrfSearch GenServer handles queueing via its mailbox.
  """

  use GenStage
  require Logger

  alias Reencodarr.AbAv1.CrfSearch
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Media

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenStage
  def init(_opts) do
    Logger.info("CRF Producer: Initializing producer")
    # Subscribe to unified Events channel for completion notifications
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())
    Logger.info("CRF Producer: Subscribed to Events channel")
    {:producer, %{demand: 0, current_video_id: nil}}
  end

  @impl GenStage
  def handle_demand(demand, state) do
    Logger.debug("CRF Producer: handle_demand(#{demand}) called")
    new_demand = state.demand + demand
    dispatch_videos(%{state | demand: new_demand})
  end

  @impl GenStage
  def handle_info({:crf_search_completed, %{video_id: video_id}}, state) do
    Logger.info("CRF Producer: CRF search completed for video #{video_id}")
    # Clear current video and dispatch pending demand if available
    new_state = %{state | current_video_id: nil}
    dispatch_videos(new_state)
  end

  @impl GenStage
  def handle_info(_msg, state), do: {:noreply, [], state}

  @impl GenStage
  def handle_cast(_msg, state), do: {:noreply, [], state}

  @impl GenStage
  def handle_call(_msg, _from, state), do: {:reply, :ok, [], state}

  # Dispatch videos based on demand and CrfSearch availability
  defp dispatch_videos(%{demand: demand, current_video_id: current_id} = state) when demand > 0 do
    available? = CrfSearch.available?()

    Logger.debug(
      "CRF Producer: demand=#{demand}, available?=#{available?}, current_video_id=#{inspect(current_id)}"
    )

    # Don't fetch new videos if we already have one in flight
    if available? and is_nil(current_id) do
      videos = Media.get_videos_for_crf_search(1)
      consumed = length(videos)
      Logger.debug("CRF Producer: fetched #{consumed} videos")

      # Track the video ID we're sending
      new_current_id = if consumed > 0, do: hd(videos).id, else: nil

      {:noreply, videos, %{state | demand: demand - consumed, current_video_id: new_current_id}}
    else
      # CrfSearch busy or video already in flight - keep demand for later
      reason = if is_nil(current_id), do: "CrfSearch busy", else: "video #{current_id} in flight"
      Logger.debug("CRF Producer: #{reason}, keeping demand")
      {:noreply, [], state}
    end
  end

  defp dispatch_videos(state) do
    Logger.debug("CRF Producer: no demand (demand=#{state.demand})")
    {:noreply, [], state}
  end
end
