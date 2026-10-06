defmodule ReencodarrWeb.DashboardLive do
  @moduledoc "Worker activity, shared queues, and library results."
  use ReencodarrWeb, :live_view

  alias Reencodarr.AbAv1.WorkerSessions
  alias Reencodarr.Core.Parsers
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Dashboard.State, as: DashboardState
  alias Reencodarr.Formatters
  alias Reencodarr.Media
  alias Reencodarr.Media.VideoQueries
  alias Reencodarr.Sync
  alias ReencodarrWeb.{DashboardComponents, WorkerActivity, WorkerControl}

  require Logger
  @worker_control_events WorkerControl.event_names()

  @impl true
  def mount(_params, _session, socket) do
    state = DashboardState.get_state()
    workers = WorkerSessions.list()
    stats = Media.get_dashboard_stats(dashboard_mount_query_timeout())

    queues =
      cond do
        Map.get(state, :queue_previews_loaded, false) -> state.queue_items
        queue_preview_hydration_enabled?() -> fetch_initial_queue_previews()
        true -> state.queue_items
      end

    socket =
      assign(socket,
        selected_queue: :encoder,
        workers: workers,
        crf_worker_data: WorkerActivity.load_worker_crf_data(workers),
        encode_worker_data: WorkerActivity.load_worker_encode_data(workers),
        stats: stats,
        stats_display: stats_display(stats),
        service_status: state.service_status,
        queue_counts: state.queue_counts,
        queue_items: queues,
        recent_encodes: VideoQueries.recent_encodes(5, dashboard_mount_query_opts()),
        sources: load_sources(),
        syncing: false,
        sync_progress: 0,
        service_type: nil,
        page_title: dashboard_page_title(state)
      )

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, DashboardState.state_channel())
      schedule_periodic_update()
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:dashboard_state_changed, state}, socket) do
    recent =
      if state.stats.encoded != socket.assigns.stats.encoded,
        do: VideoQueries.recent_encodes(5, dashboard_mount_query_opts()),
        else: socket.assigns.recent_encodes

    {:noreply,
     assign(socket,
       stats: state.stats,
       stats_display: stats_display(state.stats),
       service_status: state.service_status,
       queue_counts: state.queue_counts,
       queue_items:
         merge_queue_items_for_display(
           socket.assigns.queue_items,
           state.queue_items,
           state.queue_counts
         ),
       recent_encodes: recent,
       page_title: dashboard_page_title(state)
     )}
  end

  def handle_info({:worker_sessions_updated, %{sessions: workers}}, socket),
    do: {:noreply, assign_workers(socket, workers)}

  def handle_info({:crf_search_vmaf_result, %{video_id: id}}, socket) do
    {:noreply,
     assign(
       socket,
       :crf_worker_data,
       WorkerActivity.load_worker_crf_data(
         socket.assigns.workers,
         Map.delete(socket.assigns.crf_worker_data, id)
       )
     )}
  end

  def handle_info(:update_dashboard_data, socket) do
    schedule_periodic_update()
    {:noreply, assign_workers(socket, WorkerSessions.list())}
  end

  def handle_info({:sync_started, data}, socket),
    do:
      {:noreply,
       assign(socket, syncing: true, sync_progress: 0, service_type: data[:service_type])}

  def handle_info({:sync_progress, data}, socket),
    do: {:noreply, assign(socket, :sync_progress, Map.get(data, :progress, 0))}

  def handle_info({event, data}, socket) when event in [:sync_completed, :sync_failed] do
    socket =
      assign(socket, syncing: false, sync_progress: 0, service_type: nil, sources: load_sources())

    socket =
      if event == :sync_failed,
        do: put_flash(socket, :error, "Sync failed: #{inspect(data[:error] || "Unknown error")}"),
        else: socket

    {:noreply, socket}
  end

  @impl true
  def handle_info({:encoder_health_alert, data}, socket) do
    filename = if data.video_path, do: Path.basename(data.video_path), else: "unknown"

    message =
      case data.reason do
        :stalled_23_hours ->
          "Encoder may be stuck - no progress for 23+ hours (#{filename})"

        :killed_stuck_process ->
          "Killed stuck encoder after 24 hours of no progress (#{filename})"

        :reset_failed ->
          "Encoder reset failed - may need manual intervention (#{filename})"

        _ ->
          "Encoder health alert: #{inspect(data.reason)}"
      end

    {:noreply, put_flash(socket, :error, message)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_queue", %{"stage" => stage}, socket)
      when stage in ["analyzer", "crf_searcher", "encoder"],
      do: {:noreply, assign(socket, :selected_queue, String.to_existing_atom(stage))}

  def handle_event("select_queue", _params, socket), do: {:noreply, socket}

  def handle_event("sync_" <> service, _params, socket) do
    sync = %{
      "sonarr" => {"Sonarr", &Sync.sync_episodes/0},
      "radarr" => {"Radarr", &Sync.sync_movies/0},
      "sportarr" => {"Sportarr", &Sync.sync_sportarr/0}
    }

    case {socket.assigns.syncing, Map.fetch(sync, service)} do
      {true, _} ->
        {:noreply, put_flash(socket, :error, "Sync already in progress")}

      {false, {:ok, {name, run}}} ->
        run.()
        {:noreply, put_flash(socket, :info, "#{name} sync started")}

      {false, :error} ->
        {:noreply, put_flash(socket, :error, "Unknown sync service: #{service}")}
    end
  end

  def handle_event(event, params, socket) when event in @worker_control_events,
    do: WorkerControl.handle_event(event, params, socket)

  def handle_event("fail_queue_video", %{"id" => id_str, "stage" => stage}, socket) do
    result =
      with {:ok, id} <- Parsers.parse_integer_exact(id_str),
           {:ok, video} <- Media.fetch_video(id),
           {:ok, failure_stage} <- queue_failure_stage(stage, video),
           do: Media.fail_video_by_operator(video, failure_stage)

    case result do
      {:ok, _} ->
        GenServer.cast(DashboardState, :refresh_queues_now)
        {:noreply, put_flash(socket, :info, "Queued item removed")}

      _ ->
        {:noreply, put_flash(socket, :error, "Unable to remove queued item")}
    end
  end

  @impl true
  def render(assigns), do: DashboardComponents.dashboard(assigns)

  defp assign_workers(socket, workers) do
    assign(socket,
      workers: workers,
      crf_worker_data:
        WorkerActivity.load_worker_crf_data(workers, socket.assigns.crf_worker_data),
      encode_worker_data:
        WorkerActivity.load_worker_encode_data(workers, socket.assigns.encode_worker_data)
    )
  end

  defp schedule_periodic_update, do: Process.send_after(self(), :update_dashboard_data, 5_000)

  defp stats_display(stats) do
    %{
      total_videos: format_number(stats.total_videos),
      completed: format_number(stats.encoded),
      savings: format_savings(stats.total_savings_gb),
      failures: format_number(stats.failed)
    }
  end

  defp merge_queue_items_for_display(previous, incoming, counts) do
    %{
      analyzer:
        keep_previous_if_transient_empty(
          previous.analyzer,
          incoming.analyzer,
          counts.analyzer
        ),
      crf_searcher:
        keep_previous_if_transient_empty(
          previous.crf_searcher,
          incoming.crf_searcher,
          counts.crf_searcher
        ),
      encoder:
        keep_previous_if_transient_empty(
          previous.encoder,
          incoming.encoder,
          counts.encoder
        )
    }
  end

  defp keep_previous_if_transient_empty(previous, incoming, queue_count)
       when is_list(previous) and is_list(incoming) and is_integer(queue_count) do
    if incoming == [] and previous != [] and queue_count > 0 do
      previous
    else
      incoming
    end
  end

  defp format_number(nil), do: "—"

  defp format_number(num) when is_integer(num) do
    num
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_number(_), do: "—"

  defp format_savings(nil), do: "—"

  defp format_savings(gb) when is_number(gb) do
    # Convert GB to TiB
    tib = gb / 1024.0
    "#{:erlang.float_to_binary(tib, decimals: 2)}"
  end

  defp format_savings(_), do: "—"

  defp queue_preview_hydration_enabled? do
    Application.get_env(:reencodarr, :dashboard_queue_refresh_enabled, true) != false
  end

  defp fetch_initial_queue_previews do
    query_opts = dashboard_mount_query_opts()

    %{
      analyzer: VideoQueries.videos_needing_analysis_preview(5, query_opts),
      crf_searcher: VideoQueries.videos_for_crf_search_preview(5, query_opts),
      encoder: VideoQueries.videos_ready_for_encoding_preview(5, query_opts)
    }
  rescue
    error ->
      Logger.warning("DashboardLive initial queue preview hydration failed: #{inspect(error)}")
      %{analyzer: [], crf_searcher: [], encoder: []}
  end

  defp dashboard_mount_query_timeout do
    Application.get_env(:reencodarr, :dashboard_mount_query_timeout_ms, 1_000)
  end

  defp dashboard_mount_query_opts do
    timeout = dashboard_mount_query_timeout()
    [timeout: timeout, pool_timeout: timeout]
  end

  defp load_sources do
    configs = Map.new(Reencodarr.Services.list_configs(), &{&1.service_type, &1})

    for {type, name} <- [sonarr: "Sonarr", radarr: "Radarr", sportarr: "Sportarr"] do
      config = configs[type]

      %{
        type: type,
        name: name,
        configured: not is_nil(config),
        enabled: config && config.enabled == true,
        last_synced_at: config && config.last_synced_at
      }
    end
  end

  defp queue_failure_stage("crf_search", %{state: :analyzed}), do: {:ok, :crf_search}
  defp queue_failure_stage("encoding", %{state: :crf_searched}), do: {:ok, :encoding}
  defp queue_failure_stage(_, _), do: {:error, :invalid_queue_item}

  @doc false
  def dashboard_page_title(state) when is_map(state) do
    service_status = Map.get(state, :service_status, %{})

    [
      active_crf_title(state, Map.get(service_status, :crf_searcher)),
      active_encoding_title(state, Map.get(service_status, :encoder))
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      titles -> Enum.join(titles, " ")
    end
  end

  def dashboard_page_title(_), do: nil

  defp crf_title(%{crf_search_sample: %{sample_num: sample_num, total_samples: total_samples}})
       when is_integer(sample_num) and is_integer(total_samples) and sample_num > 0 and
              total_samples > 0 do
    "#{sample_num}/#{total_samples}"
  end

  defp crf_title(_), do: nil

  defp encoding_title(%{encoding_progress: %{percent: percent, fps: fps}})
       when not is_nil(percent) and not is_nil(fps) do
    "#{format_title_number(fps)}fps #{format_title_number(percent)}%"
  end

  defp encoding_title(_), do: nil

  defp active_crf_title(state, status) when status in [:running, :processing, :pausing] do
    crf_title(state)
  end

  defp active_crf_title(_state, _status), do: nil

  defp active_encoding_title(state, status) when status in [:running, :processing, :pausing] do
    encoding_title(state)
  end

  defp active_encoding_title(_state, _status), do: nil

  defp format_title_number(value) when is_integer(value), do: Integer.to_string(value)

  defp format_title_number(value) when is_float(value) do
    value
    |> Formatters.rate()
    |> String.replace(~r/\.0$/, "")
  end

  defp format_title_number(value) when is_binary(value), do: value
  defp format_title_number(value), do: to_string(value)
end
