defmodule Reencodarr.Encoder.Broadway.Producer do
  @moduledoc """
  Simplest possible Broadway producer for encoding.
  When demand arrives, check if Encode is available and return 1 VMAF if so.
  """

  use GenStage
  require Logger
  alias Reencodarr.AbAv1.Encode
  alias Reencodarr.Media

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
    {:producer, %{pending_demand: 0}}
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
    vmaf_list =
      if Encode.available?() do
        case Media.get_next_for_encoding(1) do
          %Reencodarr.Media.Vmaf{} = vmaf -> [vmaf]
          [%Reencodarr.Media.Vmaf{} = vmaf] -> [vmaf]
          [] -> []
          nil -> []
        end
      else
        []
      end

    remaining_demand = demand - length(vmaf_list)
    {:noreply, vmaf_list, %{state | pending_demand: remaining_demand}}
  end

  defp dispatch(_demand, state), do: {:noreply, [], state}

  defp schedule_poll do
    Process.send_after(self(), :poll, 2000)
  end
end
