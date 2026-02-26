defmodule Reencodarr.Dashboard.State do
  @moduledoc """
  Single source of truth for dashboard state.

  Subscribes to pipeline PubSub channels, maintains state that survives
  page refreshes, and broadcasts consolidated state changes on
  `state_channel()` so DashboardLive doesn't need to independently
  process the same raw events.
  """

  use GenServer
  require Logger

  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Media.VideoQueries

  @state_channel "dashboard:state"

  @stats_refresh_interval 60_000
  @queue_refresh_interval 5_000
  @query_timeout 2_000
  @progress_debounce_ms 500

  @default_state %{
    crf_search_video: nil,
    crf_search_results: [],
    crf_search_sample: nil,
    crf_progress: :none,
    encoding_video: nil,
    encoding_vmaf: nil,
    encoding_progress: :none,
    service_status: %{
      analyzer: :idle,
      crf_searcher: :idle,
      encoder: :idle
    },
    stats: nil,
    queue_counts: %{analyzer: 0, crf_searcher: 0, encoder: 0},
    queue_items: %{analyzer: [], crf_searcher: [], encoder: []},
    progress_debounce_ref: nil
  }

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the current dashboard state.
  """
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  @doc """
  Returns the PubSub channel that state change broadcasts are sent on.

  DashboardLive subscribes to this channel to receive consolidated
  `{:dashboard_state_changed, state}` messages instead of independently
  processing raw pipeline events.
  """
  def state_channel, do: @state_channel

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Subscribe to dashboard events
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())

    # Subscribe to pipeline state changes (same channels as DashboardLive)
    # PipelineStateMachine broadcasts on these via Events.pipeline_state_changed/3
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "analyzer")
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "crf_searcher")
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "encoder")

    {:ok, @default_state, {:continue, :fetch_initial_data}}
  end

  @impl true
  def handle_continue(:fetch_initial_data, state) do
    parent = self()

    Task.start(fn ->
      stats = Reencodarr.Media.get_dashboard_stats()
      send(parent, {:stats_ready, stats})
    end)

    if queue_refresh_enabled?() do
      send(self(), :refresh_queues)
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, Map.delete(state, :progress_debounce_ref), state}
  end

  @impl true
  def handle_cast(:broadcast_state, state) do
    broadcast_state(state)
    {:noreply, state}
  end

  # CRF Search Events

  @impl true
  def handle_info({:crf_search_started, video}, state) do
    service_status = Map.put(state.service_status, :crf_searcher, :processing)

    state = %{
      state
      | crf_search_video: video,
        crf_search_results: [],
        crf_search_sample: nil,
        crf_progress: :none,
        service_status: service_status
    }

    broadcast_state(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:crf_search_vmaf_result, result}, state) do
    results =
      state.crf_search_results
      |> update_or_append(result, :crf)
      |> Enum.sort_by(& &1.crf)

    state = %{state | crf_search_results: results}
    broadcast_state(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:crf_search_encoding_sample, sample}, state) do
    state = %{state | crf_search_sample: sample}
    broadcast_state(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:crf_search_progress, progress}, state) do
    # Debounce: cancel any pending flush and schedule a new one
    if state.progress_debounce_ref, do: Process.cancel_timer(state.progress_debounce_ref)
    ref = Process.send_after(self(), :flush_progress, @progress_debounce_ms)
    {:noreply, %{state | crf_progress: progress, progress_debounce_ref: ref}}
  end

  @impl true
  def handle_info(:flush_progress, state) do
    broadcast_state(state)
    {:noreply, %{state | progress_debounce_ref: nil}}
  end

  @impl true
  def handle_info({:crf_search_completed, _data}, state) do
    service_status = Map.put(state.service_status, :crf_searcher, :idle)

    state = %{
      state
      | crf_search_video: nil,
        crf_search_results: [],
        crf_search_sample: nil,
        crf_progress: :none,
        service_status: service_status
    }

    broadcast_state(state)
    {:noreply, state}
  end

  # Encoding Events

  @impl true
  def handle_info({:encoding_started, data}, state) do
    encoding_video = %{
      video_id: data.video_id,
      filename: data.filename,
      video_size: data[:video_size],
      width: data[:width],
      height: data[:height],
      hdr: data[:hdr],
      video_codecs: data[:video_codecs]
    }

    encoding_vmaf = %{
      crf: data[:crf],
      vmaf_score: data[:vmaf_score],
      predicted_percent: data[:predicted_percent],
      predicted_savings: data[:predicted_savings]
    }

    service_status = Map.put(state.service_status, :encoder, :processing)

    state = %{
      state
      | encoding_video: encoding_video,
        encoding_vmaf: encoding_vmaf,
        encoding_progress: %{percent: 0, video_id: data.video_id, filename: data.filename},
        service_status: service_status
    }

    broadcast_state(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:encoding_progress, progress}, state) do
    service_status = Map.put(state.service_status, :encoder, :processing)
    state = %{state | encoding_progress: progress, service_status: service_status}
    broadcast_state(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:encoding_completed, _data}, state) do
    service_status = Map.put(state.service_status, :encoder, :idle)

    state = %{
      state
      | encoding_video: nil,
        encoding_vmaf: nil,
        encoding_progress: :none,
        service_status: service_status
    }

    broadcast_state(state)
    {:noreply, state}
  end

  # Service Status Events from PipelineStateMachine
  # Accepts only valid pipeline states defined in PipelineStateMachine

  @pipeline_services [:analyzer, :crf_searcher, :encoder]

  @impl true
  def handle_info({service, status}, state)
      when service in @pipeline_services and is_atom(status) do
    service_status = Map.put(state.service_status, service, status)
    state = %{state | service_status: service_status}
    broadcast_state(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:stats_ready, stats}, state) do
    queue_counts = %{
      analyzer: stats.needs_analysis || 0,
      crf_searcher: stats.analyzed || 0,
      encoder: stats.crf_searched || 0
    }

    state = %{state | stats: stats, queue_counts: queue_counts}
    broadcast_state(state)
    Process.send_after(self(), :refresh_stats, @stats_refresh_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh_stats, state) do
    parent = self()

    Task.start(fn ->
      stats = Reencodarr.Media.get_dashboard_stats()
      send(parent, {:stats_ready, stats})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh_queues, state) do
    if queue_refresh_enabled?() do
      parent = self()

      Task.start(fn ->
        items = fetch_queue_items_parallel()
        send(parent, {:queue_items_ready, items})
      end)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:queue_items_ready, items}, state) do
    state = %{state | queue_items: items}
    broadcast_state(state)

    if queue_refresh_enabled?() do
      Process.send_after(self(), :refresh_queues, @queue_refresh_interval)
    end

    {:noreply, state}
  end

  # Catch-all for unknown messages
  @impl true
  def handle_info(msg, state) do
    Logger.debug("Dashboard.State received unknown message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private Helpers

  defp broadcast_state(state) do
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, @state_channel, {:dashboard_state_changed, state})
  end

  defp fetch_queue_items_parallel do
    tasks = %{
      analyzer:
        Task.async(fn ->
          safe_query_list(fn ->
            VideoQueries.videos_needing_analysis(5, timeout: @query_timeout)
          end)
        end),
      crf_searcher:
        Task.async(fn ->
          safe_query_list(fn ->
            VideoQueries.videos_for_crf_search(5, timeout: @query_timeout)
          end)
        end),
      encoder:
        Task.async(fn ->
          safe_query_list(fn ->
            VideoQueries.videos_ready_for_encoding(5, timeout: @query_timeout)
          end)
        end)
    }

    Map.new(tasks, fn {k, task} -> {k, Task.await(task, @query_timeout + 500)} end)
  end

  defp safe_query_list(fun) do
    fun.()
  rescue
    DBConnection.ConnectionError -> []
  catch
    :exit, {:timeout, _} -> []
    :exit, {%DBConnection.ConnectionError{}, _} -> []
    :exit, {{%DBConnection.ConnectionError{}, _}, _} -> []
  end

  defp queue_refresh_enabled? do
    Application.get_env(:reencodarr, :dashboard_queue_refresh_enabled, true)
  end

  # Helper to upsert a result in a list by key
  defp update_or_append(list, new_item, key) do
    key_value = Map.get(new_item, key)

    case Enum.find_index(list, &(Map.get(&1, key) == key_value)) do
      nil -> [new_item | list]
      index -> List.replace_at(list, index, new_item)
    end
  end
end
