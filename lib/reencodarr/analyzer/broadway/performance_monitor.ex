defmodule Reencodarr.Analyzer.Broadway.PerformanceMonitor do
  @moduledoc """
  Monitors Broadway performance and automatically adjusts rate limiting
  based on throughput metrics.
  """
  use GenServer
  require Logger
  alias Reencodarr.Telemetry

  @default_rate_limit 500
  @min_rate_limit 200
  @max_rate_limit 1500
  @default_mediainfo_batch_size 8
  @min_mediainfo_batch_size 5
  @max_mediainfo_batch_size 25
  # 30 seconds
  @adjustment_interval 30_000
  # 2 minutes
  @measurement_window 120_000

  defstruct [
    :broadway_name,
    :rate_limit,
    :mediainfo_batch_size,
    :message_count,
    :last_adjustment,
    :throughput_history,
    :target_throughput,
    :previous_rate_limit,
    :previous_throughput,
    :previous_mediainfo_batch_size,
    :batch_processing_times
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

  def get_current_mediainfo_batch_size do
    GenServer.call(__MODULE__, :get_mediainfo_batch_size)
  end

  def get_performance_stats do
    GenServer.call(__MODULE__, :get_performance_stats)
  end

  def get_current_throughput do
    GenServer.call(__MODULE__, :get_throughput)
  end

  @doc """
  Manually adjust performance settings (rate_limit and/or batch_size).
  Pass nil to keep current value unchanged.
  """
  def adjust_settings(rate_limit \\ nil, batch_size \\ nil) do
    GenServer.call(__MODULE__, {:adjust_settings, rate_limit, batch_size})
  end

  def record_mediainfo_batch(batch_size, duration_ms) do
    GenServer.cast(__MODULE__, {:mediainfo_batch, batch_size, duration_ms})
  end

  @impl true
  def init(broadway_name) do
    # Schedule periodic adjustments
    Process.send_after(self(), :adjust_rate_limit, @adjustment_interval)

    state = %__MODULE__{
      broadway_name: broadway_name,
      rate_limit: @default_rate_limit,
      mediainfo_batch_size: @default_mediainfo_batch_size,
      message_count: 0,
      last_adjustment: System.monotonic_time(:millisecond),
      throughput_history: [],
      # Target MB/s - adjust based on your system
      target_throughput: 200,
      previous_rate_limit: @default_rate_limit,
      previous_throughput: 0.0,
      previous_mediainfo_batch_size: @default_mediainfo_batch_size,
      batch_processing_times: []
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
    throughput = calculate_throughput(batch_size, duration_ms)

    {:noreply,
     %{
       state
       | message_count: new_count,
         throughput_history: add_to_history(state.throughput_history, throughput)
     }}
  end

  @impl true
  def handle_cast({:mediainfo_batch, batch_size, duration_ms}, state) do
    # Track mediainfo batch processing times for tuning
    new_times = add_to_history(state.batch_processing_times, {batch_size, duration_ms})

    {:noreply, %{state | batch_processing_times: new_times}}
  end

  @impl true
  def handle_call(:get_rate_limit, _from, state) do
    {:reply, state.rate_limit, state}
  end

  @impl true
  def handle_call(:get_mediainfo_batch_size, _from, state) do
    {:reply, state.mediainfo_batch_size, state}
  end

  @impl true
  def handle_call(:get_throughput, _from, state) do
    # Calculate current throughput from recent history
    current_throughput = calculate_current_throughput(state.throughput_history)

    # Convert from messages per minute to messages per second
    throughput_per_second = current_throughput / 60.0

    {:reply, Float.round(throughput_per_second, 1), state}
  end

  @impl true
  def handle_call(:get_performance_stats, _from, state) do
    current_throughput = calculate_current_throughput(state.throughput_history) / 60.0

    stats = %{
      throughput: Float.round(current_throughput, 1),
      rate_limit: state.rate_limit,
      batch_size: state.mediainfo_batch_size
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:adjust_settings, rate_limit, batch_size}, _from, state) do
    new_rate_limit = rate_limit || state.rate_limit
    new_batch_size = batch_size || state.mediainfo_batch_size

    # Validate ranges
    new_rate_limit = max(@min_rate_limit, min(@max_rate_limit, new_rate_limit))

    new_batch_size =
      max(@min_mediainfo_batch_size, min(@max_mediainfo_batch_size, new_batch_size))

    # Update Broadway rate limiting if changed
    if new_rate_limit != state.rate_limit do
      Broadway.update_rate_limiting(state.broadway_name, allowed_messages: new_rate_limit)
      Logger.info("Manually adjusted rate limit from #{state.rate_limit} to #{new_rate_limit}")
    end

    # Update Broadway context if batch size changed
    if new_batch_size != state.mediainfo_batch_size do
      update_broadway_context(state.broadway_name, new_batch_size)

      Logger.info(
        "Manually adjusted batch size from #{state.mediainfo_batch_size} to #{new_batch_size}"
      )
    end

    new_state = %{
      state
      | rate_limit: new_rate_limit,
        mediainfo_batch_size: new_batch_size,
        previous_rate_limit: state.rate_limit,
        previous_mediainfo_batch_size: state.mediainfo_batch_size
    }

    {:reply, {new_rate_limit, new_batch_size}, new_state}
  end

  @impl true
  def handle_info(:adjust_rate_limit, state) do
    # Schedule next adjustment
    Process.send_after(self(), :adjust_rate_limit, @adjustment_interval)

    # DISABLE AUTOMATIC TUNING - it's causing performance degradation
    # Just emit telemetry and keep current settings
    current_time = System.monotonic_time(:millisecond)
    time_since_last = current_time - state.last_adjustment

    # Only calculate and emit telemetry if we have enough data
    new_state =
      if length(state.throughput_history) >= 3 and time_since_last >= @adjustment_interval do
        avg_throughput = calculate_average_throughput(state.throughput_history)

        Logger.info(
          "Performance Monitor - Rate limit: #{state.rate_limit}, Batch size: #{state.mediainfo_batch_size}, " <>
            "Avg throughput: #{Float.round(avg_throughput, 2)} msgs/min, Messages in last #{time_since_last}ms: #{state.message_count}"
        )

        # Emit telemetry but don't change settings
        emit_throughput_telemetry(avg_throughput)

        # Reset counters but keep all settings the same
        %{
          state
          | message_count: 0,
            last_adjustment: current_time,
            throughput_history: add_to_history(state.throughput_history, avg_throughput)
        }
      else
        state
      end

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

  defp emit_throughput_telemetry(avg_throughput) do
    # Get current analyzer queue length for progress calculation
    queue_length = Reencodarr.Media.count_videos_needing_analysis()
    Telemetry.emit_analyzer_throughput(avg_throughput / 60.0, queue_length)
  end

  defp update_broadway_context(broadway_name, new_batch_size) do
    # Update the Broadway process context with new mediainfo batch size
    # This will be picked up by the processor on the next batch
    Broadway.producer_names(broadway_name)
    |> Enum.each(fn producer_name ->
      send(producer_name, {:update_context, %{mediainfo_batch_size: new_batch_size}})
    end)
  rescue
    error ->
      Logger.warning("Failed to update Broadway context: #{inspect(error)}")
  end

  defp calculate_average_throughput(history) do
    if length(history) > 0 do
      total = Enum.reduce(history, 0, fn {_time, throughput}, acc -> acc + throughput end)
      total / length(history)
    else
      0
    end
  end

  defp calculate_throughput(batch_size, duration_ms) when duration_ms > 0,
    do: batch_size * 60_000 / duration_ms

  defp calculate_throughput(_, _), do: 0

  # Helper function to calculate current throughput from history
  defp calculate_current_throughput([]), do: 0.0

  defp calculate_current_throughput(throughput_history) do
    calculate_average_throughput(throughput_history)
  end
end
