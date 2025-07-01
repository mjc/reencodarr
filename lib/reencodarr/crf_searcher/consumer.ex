defmodule Reencodarr.CrfSearcher.Consumer do
  @moduledoc """
  GenStage consumer for processing CRF search operations.

  This consumer subscribes to the CrfSearcher.Producer and processes videos
  by initiating CRF searches. It tracks ongoing operations and handles
  completion notifications via PubSub.
  """

  use GenStage
  require Logger

  alias Reencodarr.AbAv1

  def start_link do
    GenStage.start_link(__MODULE__, :ok)
  end

  @impl true
  def init(:ok) do
    # Subscribe to CRF search completion events
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "crf_search_events")

    # Start with no demand - we'll ask for the first video manually
    {:consumer, %{current_video_id: nil},
     subscribe_to: [{Reencodarr.CrfSearcher.Producer, min_demand: 0, max_demand: 1}]}
  end

  @impl true
  def handle_subscribe(:producer, _opts, from, state) do
    # When we first subscribe to the producer, ask for 1 video
    GenStage.ask(from, 1)
    {:manual, state}
  end

  @impl true
  def handle_events([video], _from, state) do
    Logger.info("Consumer received video #{video.id} (#{video.path}), current_video_id: #{inspect(state.current_video_id)}")

    # Check if we're already processing a video
    case state.current_video_id do
      nil ->
        Logger.info("Starting CRF search for #{video.path}")

        # Start CRF search and track the current video ID
        # Don't ask for more videos until this one completes
        AbAv1.crf_search(video, 95)
        new_state = %{state | current_video_id: video.id}

        {:noreply, [], new_state}

      current_id when current_id == video.id ->
        # Same video sent again - this shouldn't happen anymore with manual demand
        Logger.warning("Ignoring duplicate video #{video.id} - already processing")
        {:noreply, [], state}

      other_id ->
        # Different video while processing another - this is the bug we're fixing
        Logger.error("Consumer received video #{video.id} while already processing video #{other_id}! This indicates a demand management bug.")
        {:noreply, [], state}
    end
  end

  # Handle CRF search completion messages from PubSub
  @impl true
  def handle_info({:crf_search_completed, video_id, result}, %{current_video_id: video_id} = state) do
    # This is the completion for our current video
    case result do
      :success ->
        Logger.info("Completed CRF search for video #{video_id}")

      :skipped ->
        Logger.info("Skipped CRF search for video #{video_id} (already exists or reencoded)")

      {:error, exit_code} ->
        Logger.error("CRF search failed for video #{video_id} with exit code: #{exit_code}")
    end

    # Clear current video and ask for the next one from the producer
    new_state = %{state | current_video_id: nil}
    GenStage.ask(Reencodarr.CrfSearcher.Producer, 1)
    {:noreply, [], new_state}
  end

  # Ignore completion events for other videos (shouldn't happen with max_demand: 1, but just in case)
  def handle_info({:crf_search_completed, _other_video_id, _result}, state) do
    {:noreply, [], state}
  end
end
