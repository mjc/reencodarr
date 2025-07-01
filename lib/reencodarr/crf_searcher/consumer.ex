defmodule Reencodarr.CrfSearcher.Consumer do
  use GenStage
  require Logger

  alias Reencodarr.AbAv1

  def start_link() do
    GenStage.start_link(__MODULE__, :ok)
  end

  @impl true
  def init(:ok) do
    # Subscribe to CRF search completion events
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "crf_search_events")

    {:consumer, %{pending_operations: %{}},
     subscribe_to: [{Reencodarr.CrfSearcher.Producer, max_demand: 1}]}
  end

  @impl true
  def handle_events(videos, _from, state) do
    new_state =
      videos
      |> Enum.reduce(state, &process_video_with_tracking/2)

    {:noreply, [], new_state}
  end

  # Handle CRF search completion messages from PubSub
  @impl true
  def handle_info({:crf_search_completed, video_id, result}, state) do
    # Check if this operation was tracked by this consumer
    case Map.pop(state.pending_operations, video_id) do
      {nil, _pending_operations} ->
        # Operation not tracked by this consumer, ignore
        {:noreply, [], state}

      {video, new_pending} ->
        # Remove from pending operations
        new_state = %{state | pending_operations: new_pending}

        case result do
          :success ->
            Logger.info("Completed CRF search for #{video.path}")

          :skipped ->
            Logger.info("Skipped CRF search for #{video.path} (already exists or reencoded)")

          {:error, exit_code} ->
            Logger.error("CRF search failed for #{video.path} with exit code: #{exit_code}")
        end

        {:noreply, [], new_state}
    end
  end

  defp process_video_with_tracking(video, state) do
    operation_id = video.id

    # Check if this video is already being processed
    case Map.has_key?(state.pending_operations, operation_id) do
      false ->
        Logger.info("Starting CRF search for #{video.path}")

        # Start CRF search (default VMAF percent 95)
        AbAv1.crf_search(video, 95)

        # Track the operation
        new_pending = Map.put(state.pending_operations, operation_id, video)
        %{state | pending_operations: new_pending}

      true ->
        Logger.debug("CRF search already in progress for #{video.path}, skipping")
        state
    end
  end
end
