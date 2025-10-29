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
    {:producer, %{}}
  end

  @impl GenStage
  def handle_demand(_demand, state) do
    dispatch(state)
  end

  @impl GenStage
  def handle_info(:poll, state) do
    schedule_poll()
    # Check if there's work and Encode is available, wake up Broadway if so
    if Encode.available?() do
      case Media.get_next_for_encoding(1) do
        %Reencodarr.Media.Vmaf{} = vmaf -> {:noreply, [vmaf], state}
        [%Reencodarr.Media.Vmaf{} = vmaf] -> {:noreply, [vmaf], state}
        _ -> {:noreply, [], state}
      end
    else
      {:noreply, [], state}
    end
  end

  @impl GenStage
  def handle_info(_msg, state), do: {:noreply, [], state}

  defp dispatch(state) do
    if Encode.available?() do
      case Media.get_next_for_encoding(1) do
        %Reencodarr.Media.Vmaf{} = vmaf -> {:noreply, [vmaf], state}
        [%Reencodarr.Media.Vmaf{} = vmaf] -> {:noreply, [vmaf], state}
        [] -> {:noreply, [], state}
        nil -> {:noreply, [], state}
      end
    else
      {:noreply, [], state}
    end
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, 2000)
  end
end
