defmodule Reencodarr.Analyzer.QueueManager do
  @moduledoc """
  Manages analyzer queue state and broadcasts updates.

  This GenServer subscribes to analyzer queue events and maintains
  the current queue state in memory, providing fast access for
  dashboard and statistics without polling Broadway directly.

  Follows idiomatic OTP patterns with proper state management
  and PubSub for decoupled communication.
  """

  use GenServer
  require Logger

  @queue_topic "analyzer_queue"

  defstruct queue: [], count: 0

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get the current analyzer queue for dashboard display.
  """
  def get_queue do
    GenServer.call(__MODULE__, :get_queue)
  end

  @doc """
  Get the current queue count.
  """
  def get_count do
    GenServer.call(__MODULE__, :get_count)
  end

  @doc """
  Broadcast a queue update (called by Broadway producer).
  """
  def broadcast_queue_update(queue_items) do
    Phoenix.PubSub.broadcast(
      Reencodarr.PubSub,
      @queue_topic,
      {:analyzer_queue_updated, queue_items}
    )
  end

  ## Server Implementation

  @impl GenServer
  def init(_opts) do
    # Subscribe to queue updates
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, @queue_topic)

    Logger.info("Analyzer QueueManager started")
    {:ok, %__MODULE__{}}
  end

  @impl GenServer
  def handle_call(:get_queue, _from, state) do
    {:reply, state.queue, state}
  end

  @impl GenServer
  def handle_call(:get_count, _from, state) do
    {:reply, state.count, state}
  end

  @impl GenServer
  def handle_info({:analyzer_queue_updated, queue_items}, _state) do
    new_state = %{
      queue: queue_items,
      count: length(queue_items)
    }

    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
