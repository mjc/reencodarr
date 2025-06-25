defmodule Reencodarr.TelemetryReporter do
  use GenServer
  require Logger

  # Configuration constants
  @refresh_interval :timer.seconds(5)
  @telemetry_handler_id "reencodarr-reporter"

  # Default timeout for GenServer calls
  @call_timeout :timer.seconds(10)

  # Public API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_current_state do
    GenServer.call(__MODULE__, :get_state, @call_timeout)
  end

  @doc """
  Get specific part of the state for performance.
  """
  def get_progress_state do
    GenServer.call(__MODULE__, :get_progress_state, @call_timeout)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    attach_telemetry_handlers()
    schedule_refresh()

    {:ok, initial_state(), {:continue, :initial_stats}}
  end

  @impl true
  def handle_continue(:initial_stats, state) do
    send(self(), :refresh_stats)
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh_stats, %{stats_update_in_progress: true} = state) do
    {:noreply, state}
  end

  def handle_info(:refresh_stats, state) do
    Task.start(fn ->
      Logger.debug("TelemetryReporter: Fetching stats...")

      case fetch_stats_safely() do
        {:ok, stats} ->
          GenServer.cast(__MODULE__, {:update_stats, stats})

        {:error, reason} ->
          Logger.error("TelemetryReporter: Failed to fetch stats: #{inspect(reason)}")
          GenServer.cast(__MODULE__, {:stats_fetch_failed, reason})
      end
    end)

    {:noreply, %{state | stats_update_in_progress: true}}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:get_progress_state, _from, state) do
    progress_state = %{
      encoding: state.encoding,
      crf_searching: state.crf_searching,
      syncing: state.syncing,
      encoding_progress: state.encoding_progress,
      crf_search_progress: state.crf_search_progress,
      sync_progress: state.sync_progress
    }

    {:reply, progress_state, state}
  end

  @impl true
  def handle_cast({:update_stats, stats}, state) do
    Logger.debug("TelemetryReporter: Stats updated successfully")

    new_state = %{
      state
      | stats: stats,
        stats_update_in_progress: false,
        next_crf_search: stats.next_crf_search,
        videos_by_estimated_percent: stats.videos_by_estimated_percent
    }

    {:noreply, emit_state_update_and_return(new_state)}
  end

  def handle_cast({:stats_fetch_failed, error}, state) do
    Logger.error("TelemetryReporter: Stats fetch failed: #{inspect(error)}")

    new_state = %{state | stats_update_in_progress: false}
    {:noreply, new_state}
  end

  def handle_cast({:update_encoding, true, filename}, state) do
    new_state = %{
      state
      | encoding: true,
        encoding_progress: %Reencodarr.Statistics.EncodingProgress{filename: filename}
    }

    {:noreply, emit_state_update_and_return(new_state)}
  end

  def handle_cast({:update_encoding, false, _}, state) do
    new_state = %{
      state
      | encoding: false,
        encoding_progress: %Reencodarr.Statistics.EncodingProgress{}
    }

    {:noreply, emit_state_update_and_return(new_state)}
  end

  def handle_cast({:update_encoding_progress, measurements}, state) do
    # Smart merge: only update fields that have meaningful values
    current_progress = state.encoding_progress

    Logger.debug("TelemetryReporter: Updating encoding progress: #{inspect(measurements)}")

    # Merge with existing progress, preserving existing values when new ones are nil/empty
    updated_progress = smart_merge(Map.from_struct(current_progress), measurements)
    progress = struct(Reencodarr.Statistics.EncodingProgress, updated_progress)

    {:noreply, emit_state_update_and_return(%{state | encoding_progress: progress})}
  end

  def handle_cast({:update_crf_search, status}, state) do
    # If CRF search is stopping, reset the progress
    new_progress =
      if status == false do
        %Reencodarr.Statistics.CrfSearchProgress{}
      else
        state.crf_search_progress
      end

    {:noreply,
     emit_state_update_and_return(%{state | crf_searching: status, crf_search_progress: new_progress})}
  end

  def handle_cast({:update_crf_search_progress, measurements}, state) do
    # Smart merge: only update fields that have meaningful values
    current_progress = state.crf_search_progress

    Logger.debug("TelemetryReporter: Updating CRF search progress: #{inspect(measurements)}")

    # Merge with existing progress, preserving existing values when new ones are nil/empty
    updated_progress = smart_merge(Map.from_struct(current_progress), measurements)
    progress = struct(Reencodarr.Statistics.CrfSearchProgress, updated_progress)

    Logger.debug("TelemetryReporter: Final progress state: #{inspect(progress)}")
    {:noreply, emit_state_update_and_return(%{state | crf_search_progress: progress})}
  end

  def handle_cast({:update_sync, :started, _}, state) do
    {:noreply, emit_state_update_and_return(%{state | syncing: true, sync_progress: 0})}
  end

  def handle_cast({:update_sync, :completed, _}, state) do
    {:noreply, emit_state_update_and_return(%{state | syncing: false, sync_progress: 0})}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@telemetry_handler_id)
  end

  # Telemetry event handlers

  def handle_event([:reencodarr, :encoder, :started], _measurements, %{filename: filename}, _config) do
    GenServer.cast(__MODULE__, {:update_encoding, true, filename})
  end

  def handle_event([:reencodarr, :encoder, :progress], measurements, _metadata, _config) do
    GenServer.cast(__MODULE__, {:update_encoding_progress, measurements})
  end

  def handle_event([:reencodarr, :encoder, :completed], _measurements, _metadata, _config) do
    GenServer.cast(__MODULE__, {:update_encoding, false, :none})
  end

  def handle_event([:reencodarr, :encoder, :failed], measurements, metadata, _config) do
    Logger.warning("Encoding failed: #{inspect(measurements)} metadata: #{inspect(metadata)}")
    GenServer.cast(__MODULE__, {:update_encoding, false, :none})
  end

  def handle_event([:reencodarr, :crf_search, :started], _measurements, _metadata, _config) do
    GenServer.cast(__MODULE__, {:update_crf_search, true})
  end

  def handle_event([:reencodarr, :crf_search, :progress], measurements, _metadata, _config) do
    GenServer.cast(__MODULE__, {:update_crf_search_progress, measurements})
  end

  def handle_event([:reencodarr, :crf_search, :completed], _measurements, _metadata, _config) do
    GenServer.cast(__MODULE__, {:update_crf_search, false})
  end

  def handle_event([:reencodarr, :sync, event], measurements, _metadata, _config) do
    GenServer.cast(__MODULE__, {:update_sync, event, measurements})
  end

  def handle_event([:reencodarr, :media, _event], _measurements, _metadata, _config) do
    send(self(), :refresh_stats)
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  # Private helpers

  # Smart merge: only update fields with meaningful new values, preserve existing values otherwise
  defp smart_merge(current_map, new_map) do
    Enum.reduce(new_map, current_map, fn {key, new_value}, acc ->
      if meaningful_value?(key, new_value) do
        Map.put(acc, key, new_value)
      else
        # Keep existing value
        acc
      end
    end)
  end

  # Determine if a value is meaningful for updating progress
  defp meaningful_value?(_key, nil), do: false
  defp meaningful_value?(_key, ""), do: false
  defp meaningful_value?(_key, :none), do: false
  defp meaningful_value?(_key, []), do: false
  defp meaningful_value?(_key, %{} = map) when map_size(map) == 0, do: false

  # For CRF and score, 0 is not meaningful (these should be positive numbers)
  defp meaningful_value?(:crf, 0), do: false
  defp meaningful_value?(:crf, value) when is_float(value) and value == 0.0, do: false
  defp meaningful_value?(:score, 0), do: false
  defp meaningful_value?(:score, value) when is_float(value) and value == 0.0, do: false

  # For other values, 0 can be meaningful (like 0% progress at start)
  defp meaningful_value?(_key, _value), do: true

  defp initial_state do
    %{
      stats: %Reencodarr.Statistics.Stats{},
      encoding: false,
      crf_searching: false,
      encoding_progress: %Reencodarr.Statistics.EncodingProgress{},
      crf_search_progress: %Reencodarr.Statistics.CrfSearchProgress{},
      syncing: false,
      sync_progress: 0,
      stats_update_in_progress: false,
      videos_by_estimated_percent: [],
      next_crf_search: []
    }
  end

  defp attach_telemetry_handlers do
    events = [
      [:reencodarr, :encoder, :started],
      [:reencodarr, :encoder, :progress],
      [:reencodarr, :encoder, :completed],
      [:reencodarr, :encoder, :failed],
      [:reencodarr, :crf_search, :started],
      [:reencodarr, :crf_search, :progress],
      [:reencodarr, :crf_search, :completed],
      [:reencodarr, :sync, :started],
      [:reencodarr, :sync, :progress],
      [:reencodarr, :sync, :completed],
      [:reencodarr, :media, :video_upserted],
      [:reencodarr, :media, :vmaf_upserted]
    ]

    :telemetry.attach_many(@telemetry_handler_id, events, &__MODULE__.handle_event/4, nil)
  end

  defp schedule_refresh do
    :timer.send_interval(@refresh_interval, :refresh_stats)
  end

  defp emit_state_update_and_return(state) do
    # Emit telemetry event for state updates
    :telemetry.execute([:reencodarr, :dashboard, :state_updated], %{}, %{state: state})

    Logger.debug("TelemetryReporter: Emitted state update telemetry event")
    state
  end

  # Safely fetch stats with proper error handling
  defp fetch_stats_safely do
    stats = Reencodarr.Media.fetch_stats()
    {:ok, stats}
  rescue
    error -> {:error, error}
  end
end
