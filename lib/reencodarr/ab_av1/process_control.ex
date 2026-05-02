defmodule Reencodarr.AbAv1.ProcessControl do
  @moduledoc """
  Tracks operator-level suspension for ab-av1 services.

  The actual OS process is suspended by the port holder. This process keeps the
  queue gate so producers do not dispatch new CRF/encode work while an operator
  suspension is in effect.
  """

  use GenServer

  @services [:crf_searcher, :encoder]
  @initial_state %{crf_searcher: false, encoder: false}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec suspended?(atom()) :: boolean()
  def suspended?(service) when service in @services do
    call_or_default({:suspended?, service}, false)
  end

  @spec service_status(atom(), atom()) :: atom()
  def service_status(service, fallback) when service in @services and is_atom(fallback) do
    if suspended?(service), do: :paused, else: fallback
  end

  @spec suspend(atom()) :: :ok
  def suspend(service) when service in @services do
    cast_or_default({:set, service, true})
  end

  @spec resume(atom()) :: :ok
  def resume(service) when service in @services do
    cast_or_default({:set, service, false})
  end

  @impl true
  def init(_opts), do: {:ok, @initial_state}

  @impl true
  def handle_call({:suspended?, service}, _from, state) do
    {:reply, Map.get(state, service, false), state}
  end

  @impl true
  def handle_cast({:set, service, suspended?}, state) do
    {:noreply, Map.put(state, service, suspended?)}
  end

  defp call_or_default(message, default) do
    case GenServer.whereis(__MODULE__) do
      nil -> default
      pid -> GenServer.call(pid, message)
    end
  catch
    :exit, _ -> default
  end

  defp cast_or_default(message) do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, message)
    end
  end
end
