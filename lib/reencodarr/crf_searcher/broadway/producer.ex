defmodule Reencodarr.CrfSearcher.Broadway.Producer do
  @moduledoc """
  Simplest possible Broadway producer for CRF search.
  When demand arrives, check if CrfSearch is available and return 1 video if so.
  """

  use GenStage
  require Logger

  alias Reencodarr.AbAv1.CrfSearch
  alias Reencodarr.Media

  # Poll every 2 seconds to check for new work
  @poll_interval_ms 2000

  # After 900 consecutive unavailable polls (~30 minutes), attempt recovery
  @recovery_threshold 900

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenStage
  def init(_opts) do
    send(self(), :reset_orphaned)
    schedule_poll()
    {:producer, %{pending_demand: 0, consecutive_unavailable: 0}}
  end

  @impl GenStage
  def handle_demand(demand, state) do
    new_demand = state.pending_demand + demand
    dispatch(new_demand, state)
  end

  @impl GenStage
  def handle_info(:poll, state) do
    schedule_poll()
    # If there's pending demand, try to fulfill it
    dispatch(state.pending_demand, state)
  end

  @impl GenStage
  def handle_info(:reset_orphaned, state) do
    Media.reset_orphaned_crf_searching()
    {:noreply, [], state}
  end

  @impl GenStage
  def handle_info(_msg, state), do: {:noreply, [], state}

  defp dispatch(demand, state) when demand > 0 do
    status = CrfSearch.available?()

    videos =
      if status == :available do
        Media.get_videos_for_crf_search(1)
      else
        []
      end

    remaining_demand = demand - length(videos)
    # Only count :timeout (truly unresponsive) toward recovery, not :busy (normal CRF search)
    new_consecutive = update_consecutive_count(state.consecutive_unavailable, status)

    if should_attempt_recovery?(new_consecutive) do
      log_recovery_attempt(new_consecutive)
      CrfSearch.reset_if_stuck()
    end

    {:noreply, videos,
     %{state | pending_demand: remaining_demand, consecutive_unavailable: new_consecutive}}
  end

  defp dispatch(_demand, state), do: {:noreply, [], state}

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  # Public for testing
  @doc false
  # :available means CRF searcher responded and is free — reset counter
  # :busy means CRF searcher responded but is searching — reset counter (it's alive)
  # :timeout means CRF searcher didn't respond — increment toward recovery
  def update_consecutive_count(_current, :available), do: 0
  def update_consecutive_count(_current, :busy), do: 0
  def update_consecutive_count(current, :timeout), do: current + 1

  @doc false
  def should_attempt_recovery?(count) when count >= @recovery_threshold do
    rem(count, @recovery_threshold) == 0
  end

  def should_attempt_recovery?(_count), do: false

  defp log_recovery_attempt(count) do
    minutes = div(count * @poll_interval_ms, 60_000)

    Logger.warning(
      "CrfSearch has been unavailable for #{count} consecutive polls (~#{minutes} minutes). Attempting recovery..."
    )
  end
end
