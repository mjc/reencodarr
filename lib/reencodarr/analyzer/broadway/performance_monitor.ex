defmodule Reencodarr.Analyzer.Broadway.PerformanceMonitor do
  @moduledoc """
  Monitors Broadway performance and automatically adjusts rate limiting
  based on throughput metrics.
  """
  use GenServer
  require Logger

  alias Reencodarr.Dashboard.Events
  alias Reencodarr.{Media, Telemetry}

  @default_rate_limit 500
  @min_rate_limit 200
  @max_rate_limit 5000
  @default_mediainfo_batch_size 8
  @min_mediainfo_batch_size 5
  @max_mediainfo_batch_size 100
  # 30 seconds - conservative tuning interval to avoid thrashing single drives
  @adjustment_interval 30_000
  # 2 minutes - longer window for stable measurements
  @measurement_window 120_000

  # Storage performance detection thresholds
  @high_performance_threshold_mb_per_sec 500
  @ultra_high_performance_threshold_mb_per_sec 1000

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
    :batch_processing_times,
    :storage_performance_tier,
    :detected_io_throughput_mb_per_sec,
    :consecutive_improvements,
    :consecutive_degradations,
    :auto_tuning_enabled
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

  def get_storage_performance_tier do
    GenServer.call(__MODULE__, :get_storage_performance_tier)
  end

  def enable_auto_tuning do
    GenServer.call(__MODULE__, :enable_auto_tuning)
  end

  def disable_auto_tuning do
    GenServer.call(__MODULE__, :disable_auto_tuning)
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
      # Conservative target that will be adjusted based on detected storage performance
      target_throughput: 200,
      previous_rate_limit: @default_rate_limit,
      previous_throughput: 0.0,
      previous_mediainfo_batch_size: @default_mediainfo_batch_size,
      batch_processing_times: [],
      storage_performance_tier: :unknown,
      detected_io_throughput_mb_per_sec: nil,
      consecutive_improvements: 0,
      consecutive_degradations: 0,
      auto_tuning_enabled: true
    }

    Logger.info(
      "Performance monitor started with conservative defaults - " <>
        "rate limit #{@default_rate_limit}, batch size #{@default_mediainfo_batch_size}. " <>
        "Will scale up automatically based on detected storage performance."
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
  def handle_cast({:throughput_request, _requester_pid}, state) do
    # Send current throughput via PubSub instead of direct response
    current_throughput = calculate_current_throughput(state.throughput_history)
    throughput_per_second = current_throughput / 60.0
    throughput = Float.round(throughput_per_second, 1)

    # Get queue length (assume 0 if can't fetch)
    queue_length =
      try do
        Reencodarr.Media.count_videos_needing_analysis()
      catch
        _ -> 0
      end

    Events.broadcast_event(:analyzer_throughput, %{
      throughput: throughput,
      queue_length: queue_length,
      batch_size: nil
    })

    {:noreply, state}
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
      batch_size: state.mediainfo_batch_size,
      storage_tier: state.storage_performance_tier,
      auto_tuning: state.auto_tuning_enabled,
      detected_io_mb_per_sec: state.detected_io_throughput_mb_per_sec
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:get_storage_performance_tier, _from, state) do
    {:reply, state.storage_performance_tier, state}
  end

  @impl true
  def handle_call(:enable_auto_tuning, _from, state) do
    Logger.info("Auto-tuning enabled for high-performance storage")
    {:reply, :ok, %{state | auto_tuning_enabled: true}}
  end

  @impl true
  def handle_call(:disable_auto_tuning, _from, state) do
    Logger.info("Auto-tuning disabled")
    {:reply, :ok, %{state | auto_tuning_enabled: false}}
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
      # Note: Broadway rate limiting update needs to be implemented via producer messages
      send_rate_limit_update_to_producer(state.broadway_name, new_rate_limit)
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

    current_time = System.monotonic_time(:millisecond)
    time_since_last = current_time - state.last_adjustment

    # Only process if we have enough data and auto-tuning is enabled
    new_state =
      if length(state.throughput_history) >= 3 and time_since_last >= @adjustment_interval do
        avg_throughput = calculate_average_throughput(state.throughput_history)

        # Detect storage performance and adjust settings accordingly
        state_with_storage_detection = detect_and_adapt_to_storage_performance(state)

        if state_with_storage_detection.auto_tuning_enabled do
          # Perform intelligent auto-tuning based on storage tier
          perform_intelligent_tuning(state_with_storage_detection, avg_throughput, current_time)
        else
          # Just emit telemetry and reset counters
          emit_telemetry_and_reset_counters(
            state_with_storage_detection,
            avg_throughput,
            current_time
          )
        end
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

  defp emit_throughput_telemetry(avg_throughput, state) do
    # Get current analyzer queue length for progress calculation
    queue_length = get_queue_length()
    rate_limit = state.rate_limit
    batch_size = state.mediainfo_batch_size

    Telemetry.emit_analyzer_throughput(
      avg_throughput / 60.0,
      queue_length,
      rate_limit,
      batch_size
    )
  end

  defp get_queue_length do
    Media.count_videos_needing_analysis()
  end

  defp update_broadway_context(broadway_name, new_batch_size) do
    # Send update message to Broadway producer
    send_context_update_to_producer(broadway_name, new_batch_size)
  end

  defp send_rate_limit_update_to_producer(_broadway_name, new_rate_limit) do
    # Send message to Broadway producer via the main Broadway process
    # Use Broadway's built-in rate limiting update mechanism
    Logger.debug("Updating rate limit to #{new_rate_limit} via Broadway process")
    # For now, just log the update - Broadway doesn't expose runtime rate limit updates
    Logger.info(
      "Rate limit would be updated to #{new_rate_limit} (update mechanism not available)"
    )
  rescue
    error ->
      Logger.warning("Failed to send rate limit update to producer: #{inspect(error)}")
  end

  defp send_context_update_to_producer(broadway_name, new_batch_size) do
    # Send message to the Broadway producer process
    # Find the producer process for this Broadway pipeline
    producer_name = :"#{broadway_name}.Producer_0"

    case Process.whereis(producer_name) do
      nil ->
        Logger.debug("Producer process #{producer_name} not found")

      producer_pid ->
        send(producer_pid, {:update_context, %{mediainfo_batch_size: new_batch_size}})
        Logger.debug("Sent context update to producer #{producer_name}")
    end
  rescue
    error ->
      Logger.warning("Failed to send context update to producer: #{inspect(error)}")
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

  # Smart self-tuning functions for high-performance storage

  defp detect_and_adapt_to_storage_performance(state) do
    # Estimate I/O throughput based on mediainfo batch processing times
    estimated_io_throughput = estimate_io_throughput_from_batches(state.batch_processing_times)

    new_tier = classify_storage_performance(estimated_io_throughput)

    if new_tier != state.storage_performance_tier do
      Logger.info(
        "Storage performance tier changed: #{state.storage_performance_tier} -> #{new_tier} (#{estimated_io_throughput} MB/s estimated)"
      )

      # Adjust target throughput based on detected storage tier
      new_target = calculate_target_throughput_for_tier(new_tier)

      %{
        state
        | storage_performance_tier: new_tier,
          detected_io_throughput_mb_per_sec: estimated_io_throughput,
          target_throughput: new_target
      }
    else
      %{state | detected_io_throughput_mb_per_sec: estimated_io_throughput}
    end
  end

  defp estimate_io_throughput_from_batches(batch_times) when length(batch_times) < 3, do: nil

  defp estimate_io_throughput_from_batches(batch_times) do
    # Use recent batches to estimate I/O throughput
    recent_batches = Enum.take(batch_times, 5)

    total_files =
      Enum.reduce(recent_batches, 0, fn {_time, {batch_size, _duration}}, acc ->
        acc + batch_size
      end)

    total_time_seconds =
      Enum.reduce(recent_batches, 0, fn {_time, {_batch_size, duration_ms}}, acc ->
        acc + duration_ms / 1000.0
      end)

    if total_time_seconds > 0 do
      # Estimate ~10MB average file size for video files, adjust processing rate accordingly
      avg_file_size_mb = 10
      estimated_mb_per_sec = total_files * avg_file_size_mb / total_time_seconds

      # Cap unrealistic estimates
      min(estimated_mb_per_sec, 2000)
    else
      nil
    end
  end

  defp classify_storage_performance(nil), do: :unknown

  defp classify_storage_performance(mb_per_sec)
       when mb_per_sec >= @ultra_high_performance_threshold_mb_per_sec,
       do: :ultra_high_performance

  defp classify_storage_performance(mb_per_sec)
       when mb_per_sec >= @high_performance_threshold_mb_per_sec, do: :high_performance

  defp classify_storage_performance(_), do: :standard

  defp calculate_target_throughput_for_tier(:ultra_high_performance), do: 1000
  defp calculate_target_throughput_for_tier(:high_performance), do: 600
  defp calculate_target_throughput_for_tier(:standard), do: 300
  defp calculate_target_throughput_for_tier(:unknown), do: 400

  defp perform_intelligent_tuning(state, avg_throughput, current_time) do
    # Calculate performance compared to target
    throughput_ratio =
      if state.target_throughput > 0, do: avg_throughput / state.target_throughput, else: 1.0

    # Determine if we should increase or decrease settings
    {new_rate_limit, new_batch_size, improvements, degradations} =
      if throughput_ratio < 0.8 do
        # Performance is below target - increase settings aggressively for high-perf storage
        increase_performance_settings(state, throughput_ratio)
      else
        # Performance is good - try modest increases or maintain current settings
        optimize_performance_settings(state, throughput_ratio)
      end

    # Apply changes and update state
    apply_performance_changes(
      state,
      new_rate_limit,
      new_batch_size,
      avg_throughput,
      current_time,
      improvements,
      degradations
    )
  end

  defp increase_performance_settings(state, _throughput_ratio) do
    # Start conservative, scale aggressively once high performance is detected
    multiplier =
      case state.storage_performance_tier do
        # Aggressive scaling for RAID arrays
        :ultra_high_performance -> 2.0
        # Moderate scaling for fast storage
        :high_performance -> 1.5
        # Conservative for standard storage
        :standard -> 1.2
        # Very conservative until we know performance
        :unknown -> 1.1
      end

    # Only adjust batch size for now since Broadway rate limiting can't be changed at runtime
    # Keep current rate limit
    new_rate_limit = state.rate_limit

    new_batch_size =
      min(round(state.mediainfo_batch_size * multiplier), @max_mediainfo_batch_size)

    improvements =
      if new_batch_size > state.mediainfo_batch_size do
        state.consecutive_improvements + 1
      else
        0
      end

    {new_rate_limit, new_batch_size, improvements, 0}
  end

  defp optimize_performance_settings(state, throughput_ratio) do
    # Try modest increases if we have consecutive improvements, otherwise maintain
    if state.consecutive_improvements >= 2 and throughput_ratio > 1.1 do
      # Only adjust batch size since rate limit can't be changed at runtime
      new_rate_limit = state.rate_limit
      new_batch_size = min(round(state.mediainfo_batch_size * 1.1), @max_mediainfo_batch_size)

      {new_rate_limit, new_batch_size, state.consecutive_improvements + 1, 0}
    else
      # Maintain current settings
      {state.rate_limit, state.mediainfo_batch_size, 0, 0}
    end
  end

  defp apply_performance_changes(
         state,
         new_rate_limit,
         new_batch_size,
         avg_throughput,
         current_time,
         improvements,
         degradations
       ) do
    # Update Broadway settings if they changed
    settings_changed = new_batch_size != state.mediainfo_batch_size

    if settings_changed do
      if new_batch_size != state.mediainfo_batch_size do
        update_broadway_context(state.broadway_name, new_batch_size)

        Logger.info(
          "Auto-tuned batch size: #{state.mediainfo_batch_size} -> #{new_batch_size} (#{state.storage_performance_tier} storage)"
        )
      end
    end

    # Log performance summary
    Logger.info(
      "Performance Monitor (#{state.storage_performance_tier}) - " <>
        "Batch: #{new_batch_size}, Throughput: #{Float.round(avg_throughput, 2)} files/min, " <>
        "Target: #{state.target_throughput}, Consecutive improvements: #{improvements}"
    )

    # Emit telemetry
    emit_throughput_telemetry(avg_throughput, state)

    # Reset counters and update state
    %{
      state
      | rate_limit: new_rate_limit,
        mediainfo_batch_size: new_batch_size,
        message_count: 0,
        last_adjustment: current_time,
        previous_rate_limit: state.rate_limit,
        previous_mediainfo_batch_size: state.mediainfo_batch_size,
        consecutive_improvements: improvements,
        consecutive_degradations: degradations,
        throughput_history: add_to_history(state.throughput_history, avg_throughput)
    }
  end

  defp emit_telemetry_and_reset_counters(state, avg_throughput, current_time) do
    Logger.info(
      "Performance Monitor (auto-tuning disabled) - Rate: #{state.rate_limit}, " <>
        "Batch: #{state.mediainfo_batch_size}, Throughput: #{Float.round(avg_throughput, 2)} files/min"
    )

    emit_throughput_telemetry(avg_throughput, state)

    %{
      state
      | message_count: 0,
        last_adjustment: current_time,
        throughput_history: add_to_history(state.throughput_history, avg_throughput)
    }
  end
end
