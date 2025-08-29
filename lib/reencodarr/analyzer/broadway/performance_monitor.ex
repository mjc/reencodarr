defmodule Reencodarr.Analyzer.Broadway.PerformanceMonitor do
  @moduledoc """
  Monitors Broadway performance and automatically adjusts rate limiting
  based on throughput metrics.
  """
  use GenServer
  require Logger

  @default_rate_limit 1000
  @min_rate_limit 200
  @max_rate_limit 3000
  # 30 seconds
  @adjustment_interval 30_000
  # 2 minutes
  @measurement_window 120_000

  defstruct [
    :broadway_name,
    :rate_limit,
    :message_count,
    :last_adjustment,
    :throughput_history,
    :target_throughput
  ]

  def start_link(broadway_name) do
    GenServer.start_link(__MODULE__, broadway_name, name: __MODULE__)
  end

  def record_batch_processed(batch_size, duration_ms) do
    GenServer.cast(__MODULE__, {:batch_processed, batch_size, duration_ms})
  end

  def get_current_rate_limit do
    GenServer.call(__MODULE__, :get_rate_limit)
  end

  @impl true
  def init(broadway_name) do
    # Schedule periodic adjustments
    Process.send_after(self(), :adjust_rate_limit, @adjustment_interval)

    state = %__MODULE__{
      broadway_name: broadway_name,
      rate_limit: @default_rate_limit,
      message_count: 0,
      last_adjustment: System.monotonic_time(:millisecond),
      throughput_history: [],
      # Target MB/s - adjust based on your system
      target_throughput: 200
    }

    Logger.info(
      "Performance monitor started for #{broadway_name} with initial rate limit #{@default_rate_limit}"
    )

    {:ok, state}
  end

  @impl true
  def handle_cast({:batch_processed, batch_size, duration_ms}, state) do
    new_count = state.message_count + batch_size

    # Calculate throughput (messages per minute)
    throughput = if duration_ms > 0, do: batch_size * 60_000 / duration_ms, else: 0

    {:noreply,
     %{
       state
       | message_count: new_count,
         throughput_history: add_to_history(state.throughput_history, throughput)
     }}
  end

  @impl true
  def handle_call(:get_rate_limit, _from, state) do
    {:reply, state.rate_limit, state}
  end

  @impl true
  def handle_info(:adjust_rate_limit, state) do
    # Schedule next adjustment
    Process.send_after(self(), :adjust_rate_limit, @adjustment_interval)

    new_state = adjust_rate_limit_based_on_performance(state)
    {:noreply, new_state}
  end

  defp add_to_history(history, throughput) do
    now = System.monotonic_time(:millisecond)
    # Add new measurement with timestamp
    new_history = [{now, throughput} | history]

    # Keep only measurements from the last 2 minutes
    cutoff = now - @measurement_window
    Enum.filter(new_history, fn {timestamp, _} -> timestamp > cutoff end)
  end

  defp adjust_rate_limit_based_on_performance(state) do
    current_time = System.monotonic_time(:millisecond)
    time_since_last = current_time - state.last_adjustment

    # Only adjust if we have enough data and time has passed
    if length(state.throughput_history) >= 3 and time_since_last >= @adjustment_interval do
      avg_throughput = calculate_average_throughput(state.throughput_history)
      messages_per_interval = state.message_count

      Logger.debug(
        "Performance metrics - Rate limit: #{state.rate_limit}, Avg throughput: #{Float.round(avg_throughput, 2)} msgs/min, Messages in last #{time_since_last}ms: #{messages_per_interval}"
      )

      new_rate_limit =
        calculate_new_rate_limit(
          state.rate_limit,
          avg_throughput,
          messages_per_interval,
          time_since_last
        )

      if new_rate_limit != state.rate_limit do
        Logger.info(
          "Adjusting Broadway rate limit from #{state.rate_limit} to #{new_rate_limit} (avg throughput: #{Float.round(avg_throughput, 2)} msgs/min)"
        )

        Broadway.update_rate_limiting(state.broadway_name, allowed_messages: new_rate_limit)
      end

      %{state | rate_limit: new_rate_limit, message_count: 0, last_adjustment: current_time}
    else
      state
    end
  end

  defp calculate_average_throughput(history) do
    if length(history) > 0 do
      total = Enum.reduce(history, 0, fn {_time, throughput}, acc -> acc + throughput end)
      total / length(history)
    else
      0
    end
  end

  defp calculate_new_rate_limit(
         current_rate,
         avg_throughput,
         messages_processed,
         time_interval_ms
       ) do
    # Calculate actual message rate over the interval (messages per minute)
    actual_rate =
      if time_interval_ms > 0, do: messages_processed * 60_000 / time_interval_ms, else: 0

    cond do
      # If we're processing very fast and close to rate limit, increase it
      # 3000 msgs/min = 50 msgs/s (high throughput for video processing)
      actual_rate > current_rate * 0.8 and avg_throughput > 3000 ->
        min(@max_rate_limit, trunc(current_rate * 1.3))

      # If we're processing slowly, decrease rate limit to reduce pressure
      # 600 msgs/min = 10 msgs/s (low throughput)
      avg_throughput < 600 and actual_rate < current_rate * 0.3 ->
        max(@min_rate_limit, trunc(current_rate * 0.7))

      # If throughput is moderate but we're not hitting rate limit, slight increase
      # 1500 msgs/min = 25 msgs/s (moderate throughput)
      avg_throughput > 1500 and actual_rate < current_rate * 0.5 ->
        min(@max_rate_limit, trunc(current_rate * 1.1))

      # Otherwise keep current rate
      true ->
        current_rate
    end
  end
end
