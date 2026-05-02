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
  alias Reencodarr.Media.ChartQueries
  alias Reencodarr.Media.VideoQueries

  @state_channel "dashboard:state"

  @queue_refresh_interval 5_000
  @chart_refresh_interval 300_000
  @default_queue_query_timeout 1_000
  @progress_debounce_ms 500
  @tracked_video_states [
    :needs_analysis,
    :analyzed,
    :crf_searching,
    :crf_searched,
    :encoding,
    :encoded,
    :failed
  ]

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
    stats: Reencodarr.Media.get_default_stats(),
    queue_counts: %{analyzer: 0, crf_searcher: 0, encoder: 0},
    queue_items: %{analyzer: [], crf_searcher: [], encoder: []},
    vmaf_distribution: [],
    resolution_distribution: [],
    codec_distribution: [],
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
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "video_state_transitions")

    # Subscribe to pipeline state changes (same channels as DashboardLive)
    # PipelineStateMachine broadcasts on these via Events.pipeline_state_changed/3
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "analyzer")
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "crf_searcher")
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "encoder")

    {:ok, @default_state, {:continue, :fetch_initial_data}}
  end

  @impl true
  def handle_continue(:fetch_initial_data, state) do
    stats = load_initial_dashboard_stats(state.stats)
    queue_counts = refresh_queue_counts(state.queue_counts, stats)

    if queue_refresh_enabled?() do
      send(self(), :refresh_queues)
    end

    state = %{state | stats: stats, queue_counts: queue_counts}
    broadcast_state(state)

    # Defer chart data loading to avoid database lock contention during startup
    Process.send_after(self(), :load_charts, 2_000)
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

  @impl true
  def handle_cast(:refresh_queues_now, state) do
    items = fetch_queue_items(state.queue_items)
    state = %{state | queue_items: items}
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
  def handle_info({:video_mutated, mutation}, state) when is_map(mutation) do
    state = apply_video_mutation(state, mutation)
    broadcast_state(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:vmaf_mutated, mutation}, state) when is_map(mutation) do
    state = %{state | stats: apply_vmaf_mutation(state.stats, mutation)}
    broadcast_state(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:crf_search_vmaf_result, result}, state) do
    normalized_result = normalize_crf_search_result(result)

    results =
      state.crf_search_results
      |> update_or_append(normalized_result, :crf)
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

  @impl true
  def handle_info({:process_control_changed, %{service: service, status: status}}, state)
      when service in [:crf_searcher, :encoder] and is_atom(status) do
    service_status = Map.put(state.service_status, service, status)
    state = %{state | service_status: service_status}
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
  def handle_info(:load_charts, state) do
    charts = load_chart_data()

    state = %{
      state
      | vmaf_distribution: charts.vmaf,
        resolution_distribution: charts.resolution,
        codec_distribution: charts.codec
    }

    broadcast_state(state)
    Process.send_after(self(), :refresh_charts, @chart_refresh_interval)
    {:noreply, state}
  rescue
    error ->
      Logger.warning("Dashboard.State load_charts failed: #{inspect(error)}")
      Process.send_after(self(), :load_charts, @chart_refresh_interval)
      {:noreply, state}
  end

  @impl true
  def handle_info(:refresh_queues, state) do
    if queue_refresh_enabled?() do
      items = fetch_queue_items(state.queue_items)
      state = %{state | queue_items: items}
      broadcast_state(state)
      Process.send_after(self(), :refresh_queues, @queue_refresh_interval)
    end

    {:noreply, state}
  rescue
    error ->
      Logger.warning("Dashboard.State refresh_queues failed: #{inspect(error)}")

      if queue_refresh_enabled?() do
        Process.send_after(self(), :refresh_queues, @queue_refresh_interval)
      end

      {:noreply, state}
  end

  @impl true
  def handle_info(:refresh_charts, state) do
    charts = load_chart_data()

    state = %{
      state
      | vmaf_distribution: charts.vmaf,
        resolution_distribution: charts.resolution,
        codec_distribution: charts.codec
    }

    broadcast_state(state)
    Process.send_after(self(), :refresh_charts, @chart_refresh_interval)
    {:noreply, state}
  rescue
    error ->
      Logger.warning("Dashboard.State refresh_charts failed: #{inspect(error)}")
      Process.send_after(self(), :refresh_charts, @chart_refresh_interval)
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

  defp fetch_queue_items(current_items) do
    query_opts = queue_query_opts()

    %{
      analyzer:
        fetch_queue_preview(
          "analyzer",
          current_items.analyzer,
          fn -> VideoQueries.videos_needing_analysis_preview(5, query_opts) end
        ),
      crf_searcher:
        fetch_queue_preview(
          "crf_searcher",
          current_items.crf_searcher,
          fn -> VideoQueries.videos_for_crf_search_preview(5, query_opts) end
        ),
      encoder:
        fetch_queue_preview(
          "encoder",
          current_items.encoder,
          fn -> VideoQueries.videos_ready_for_encoding_preview(5, query_opts) end
        )
    }
  end

  defp load_initial_dashboard_stats(current_stats) do
    current_stats |> Map.merge(Reencodarr.Media.get_dashboard_stats())
  rescue
    _error -> current_stats
  end

  defp refresh_queue_counts(current_queue_counts, stats) do
    %{
      analyzer: stats.needs_analysis || current_queue_counts.analyzer || 0,
      crf_searcher: stats.analyzed || current_queue_counts.crf_searcher || 0,
      encoder: stats.encoding_queue_count || current_queue_counts.encoder || 0
    }
  end

  defp queue_refresh_enabled? do
    Application.get_env(:reencodarr, :dashboard_queue_refresh_enabled, true)
  end

  defp fetch_queue_preview(label, fallback, fun) do
    fun.()
  rescue
    error in [DBConnection.ConnectionError, Exqlite.Error] ->
      Logger.debug(
        "Dashboard.State #{label} queue preview failed, keeping previous items: #{inspect(error)}"
      )

      fallback
  catch
    :exit, {:timeout, _} ->
      Logger.debug("Dashboard.State #{label} queue preview timed out, keeping previous items")
      fallback
  end

  defp normalize_crf_search_result(result) when is_map(result) do
    score = Map.get(result, :score, Map.get(result, :vmaf_score))
    percent = Map.get(result, :percent, Map.get(result, :vmaf_percentile))

    result
    |> Map.put(:score, score)
    |> Map.put(:percent, percent)
  end

  defp queue_query_timeout do
    Application.get_env(
      :reencodarr,
      :dashboard_queue_query_timeout_ms,
      @default_queue_query_timeout
    )
  end

  defp queue_query_opts do
    timeout = queue_query_timeout()
    [timeout: timeout, pool_timeout: timeout]
  end

  # Helper to upsert a result in a list by key
  defp update_or_append(list, new_item, key) do
    key_value = Map.get(new_item, key)

    case Enum.find_index(list, &(Map.get(&1, key) == key_value)) do
      nil -> [new_item | list]
      index -> List.replace_at(list, index, new_item)
    end
  end

  defp load_chart_data do
    %{
      vmaf: ChartQueries.vmaf_score_distribution(),
      resolution: ChartQueries.resolution_distribution(),
      codec: ChartQueries.codec_distribution()
    }
  end

  defp apply_video_mutation(state, %{action: action, old_video: old_video, new_video: new_video})
       when action in [:insert, :update, :delete] do
    stats =
      state.stats
      |> apply_total_video_delta(action)
      |> apply_total_size_delta(old_video, new_video)
      |> apply_state_count_deltas(old_video, new_video)
      |> apply_chosen_vmaf_delta(old_video, new_video)
      |> apply_encoding_queue_delta(old_video, new_video)
      |> apply_total_savings_delta(old_video, new_video)
      |> apply_recent_video_timestamps(new_video)

    queue_counts =
      state.queue_counts
      |> update_queue_count(
        :analyzer,
        queue_member?(old_video, :analyzer),
        queue_member?(new_video, :analyzer)
      )
      |> update_queue_count(
        :crf_searcher,
        queue_member?(old_video, :crf_searcher),
        queue_member?(new_video, :crf_searcher)
      )
      |> update_queue_count(
        :encoder,
        queue_member?(old_video, :encoder),
        queue_member?(new_video, :encoder)
      )

    %{state | stats: stats, queue_counts: queue_counts}
  end

  defp apply_video_mutation(state, _mutation), do: state

  defp apply_vmaf_mutation(stats, %{action: :insert, count: count}) when is_integer(count),
    do: increment_stat(stats, :total_vmafs, count)

  defp apply_vmaf_mutation(stats, %{action: :delete, count: count}) when is_integer(count),
    do: increment_stat(stats, :total_vmafs, -count)

  defp apply_vmaf_mutation(stats, _mutation), do: stats

  defp apply_total_video_delta(stats, :insert), do: increment_stat(stats, :total_videos, 1)
  defp apply_total_video_delta(stats, :delete), do: increment_stat(stats, :total_videos, -1)
  defp apply_total_video_delta(stats, :update), do: stats

  defp apply_total_size_delta(stats, old_video, new_video) do
    delta_bytes = snapshot_size(new_video) - snapshot_size(old_video)
    current_total_size_gb = Map.get(stats, :total_size_gb, 0.0)
    delta_gb = delta_bytes / :math.pow(1024, 3)

    Map.put(stats, :total_size_gb, Float.round(current_total_size_gb + delta_gb, 2))
  end

  defp apply_state_count_deltas(stats, old_video, new_video) do
    stats
    |> decrement_state_count(old_video)
    |> increment_state_count(new_video)
  end

  defp decrement_state_count(stats, %{state: state}) when state in @tracked_video_states,
    do: increment_stat(stats, state, -1)

  defp decrement_state_count(stats, _video), do: stats

  defp increment_state_count(stats, %{state: state}) when state in @tracked_video_states,
    do: increment_stat(stats, state, 1)

  defp increment_state_count(stats, _video), do: stats

  defp apply_encoding_queue_delta(stats, old_video, new_video) do
    old_value = if queue_member?(old_video, :encoder), do: 1, else: 0
    new_value = if queue_member?(new_video, :encoder), do: 1, else: 0
    increment_stat(stats, :encoding_queue_count, new_value - old_value)
  end

  defp apply_chosen_vmaf_delta(stats, old_video, new_video) do
    old_value = if chosen_vmaf_selected?(old_video), do: 1, else: 0
    new_value = if chosen_vmaf_selected?(new_video), do: 1, else: 0
    increment_stat(stats, :chosen_vmafs, new_value - old_value)
  end

  defp apply_total_savings_delta(stats, old_video, new_video) do
    delta_bytes = snapshot_savings_bytes(new_video) - snapshot_savings_bytes(old_video)
    current_total_savings_gb = Map.get(stats, :total_savings_gb, 0.0)
    delta_gb = delta_bytes / :math.pow(1024, 3)

    Map.put(
      stats,
      :total_savings_gb,
      Float.round(max(current_total_savings_gb + delta_gb, 0.0), 2)
    )
  end

  defp apply_recent_video_timestamps(stats, %{updated_at: updated_at} = video) do
    stats
    |> maybe_put_latest_timestamp(:most_recent_video_update, updated_at)
    |> maybe_put_latest_timestamp(:most_recent_inserted_video, Map.get(video, :inserted_at))
  end

  defp apply_recent_video_timestamps(stats, _video), do: stats

  defp update_queue_count(queue_counts, key, old_member, new_member) do
    delta = truthy_to_int(new_member) - truthy_to_int(old_member)
    Map.update(queue_counts, key, max(delta, 0), &max(&1 + delta, 0))
  end

  defp queue_member?(%{state: :needs_analysis}, :analyzer), do: true
  defp queue_member?(%{state: :analyzed}, :crf_searcher), do: true

  defp queue_member?(%{state: :crf_searched, chosen_vmaf_id: chosen_vmaf_id}, :encoder),
    do: not is_nil(chosen_vmaf_id)

  defp queue_member?(_video, _queue), do: false

  defp snapshot_size(%{size: size}) when is_number(size), do: size
  defp snapshot_size(_video), do: 0

  defp snapshot_savings_bytes(%{state: :encoded, original_size: original_size, size: size})
       when is_number(original_size) and is_number(size) and original_size > size do
    original_size - size
  end

  defp snapshot_savings_bytes(%{state: state, chosen_vmaf_savings: savings})
       when state != :encoded and is_number(savings) and savings > 0 do
    savings
  end

  defp snapshot_savings_bytes(_video), do: 0

  defp chosen_vmaf_selected?(%{chosen_vmaf_id: chosen_vmaf_id}), do: not is_nil(chosen_vmaf_id)
  defp chosen_vmaf_selected?(_video), do: false

  defp maybe_put_latest_timestamp(stats, _key, nil), do: stats

  defp maybe_put_latest_timestamp(stats, key, candidate) do
    current = Map.get(stats, key)

    if newer_timestamp?(candidate, current) do
      Map.put(stats, key, candidate)
    else
      stats
    end
  end

  defp newer_timestamp?(candidate, nil), do: not is_nil(candidate)
  defp newer_timestamp?(nil, _current), do: false

  defp newer_timestamp?(%DateTime{} = candidate, %DateTime{} = current) do
    DateTime.compare(candidate, current) == :gt
  end

  defp newer_timestamp?(candidate, current), do: candidate > current

  defp increment_stat(stats, key, delta) do
    Map.update(stats, key, max(delta, 0), &max(&1 + delta, 0))
  end

  defp truthy_to_int(true), do: 1
  defp truthy_to_int(_), do: 0
end
