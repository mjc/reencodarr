defmodule Reencodarr.Encoder.Broadway.Producer do
  @moduledoc """
  Simplest possible Broadway producer for encoding.
  When demand arrives, check if Encode is available and return 1 VMAF if so.
  """

  use GenStage
  require Logger
  alias Reencodarr.AbAv1.Encode
  alias Reencodarr.Media

  # Poll every 2 seconds to check for new work
  @poll_interval_ms 2000

  # After 900 consecutive unavailable polls (~30 minutes), attempt recovery
  @recovery_threshold 900

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def dispatch_available do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :producer_not_found}
      pid -> send(pid, :poll)
    end
  end

  @impl GenStage
  def init(_opts) do
    # Poll every 2 seconds to check for new work
    schedule_poll()
    {:producer, %{pending_demand: 0, consecutive_unavailable: 0}, {:continue, :reset_orphaned}}
  end

  def handle_continue(:reset_orphaned, state) do
    Media.reset_orphaned_encoding()
    {:noreply, [], state}
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
  def handle_info(_msg, state), do: {:noreply, [], state}

  defp dispatch(demand, state) when demand > 0 do
    status = Encode.available?()

    vmaf_list =
      if status == :available do
        case Media.get_next_for_encoding(1) do
          [%Reencodarr.Media.Vmaf{} = vmaf] -> [vmaf]
          [] -> []
        end
      else
        []
      end

    remaining_demand = demand - length(vmaf_list)
    # Only count :timeout (truly unresponsive) toward recovery, not :busy (normal encoding)
    new_consecutive = update_consecutive_count(state.consecutive_unavailable, status)

    if should_attempt_recovery?(new_consecutive) do
      log_recovery_attempt(new_consecutive)
      Encode.reset_if_stuck()
    end

    {:noreply, vmaf_list,
     %{state | pending_demand: remaining_demand, consecutive_unavailable: new_consecutive}}
  end

  defp dispatch(_demand, state), do: {:noreply, [], state}

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  # Public for testing
  @doc false
  # :available means encoder responded and is free — reset counter
  # :busy means encoder responded but is encoding — reset counter (it's alive)
  # :timeout means encoder didn't respond — increment toward recovery
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
      "Encode has been unavailable for #{count} consecutive polls (~#{minutes} minutes). Attempting recovery..."
    )
  end
end
