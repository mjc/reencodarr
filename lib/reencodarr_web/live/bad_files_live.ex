defmodule ReencodarrWeb.BadFilesLive do
  use ReencodarrWeb, :live_view

  alias Reencodarr.BadFileRemediation
  alias Reencodarr.BadFiles.State, as: BadFilesState
  alias Reencodarr.Core.Parsers
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Media
  alias Reencodarr.Media.BadFileIssue
  alias ReencodarrWeb.Live.FlopList

  @update_interval 30_000
  @per_page_options [25, 50, 100, 250]
  @default_per_page 50
  @status_filter_values [
    "all",
    "open",
    "queued",
    "processing",
    "waiting_for_replacement",
    "failed",
    "resolved"
  ]
  @service_filter_values ["all", "sonarr", "sportarr", "radarr"]
  @kind_filter_values ["all" | Enum.map(BadFileIssue.issue_kind_values(), &to_string/1)]
  @param_keys [:status_filter, :service_filter, :kind_filter, :search_query, :page, :per_page]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        per_page_options: @per_page_options,
        status_filter_values: @status_filter_values,
        service_filter_values: @service_filter_values,
        kind_filter_values: @kind_filter_values,
        page: 1,
        per_page: @default_per_page,
        status_filter: "all",
        service_filter: "all",
        kind_filter: "all",
        search_query: "",
        loading_issues: true,
        show_resolved: false,
        loaded_once: false,
        issues: [],
        meta: %Flop.Meta{},
        url_query: %{},
        tracked_count: 0,
        active_total: 0,
        active_issues: [],
        replacement_issues: [],
        resolved_issues: [],
        issue_summary: %{
          open: 0,
          queued: 0,
          processing: 0,
          waiting_for_replacement: 0,
          failed: 0,
          resolved: 0
        }
      )

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())
      Process.send_after(self(), :periodic_update, @update_interval)
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = parse_params(params)
    filters_changed? = filters_changed?(socket.assigns, filters)

    socket =
      socket
      |> assign(filters)
      |> assign_url_query()
      |> reload_issues_for_params(filters_changed?)

    {:noreply, socket}
  end

  @impl true
  def handle_info(:periodic_update, socket) do
    Process.send_after(self(), :periodic_update, @update_interval)
    {:noreply, if(socket.assigns.loaded_once, do: async_load_issues(socket), else: socket)}
  end

  @impl true
  def handle_info({event, _data}, socket)
      when event in [:sync_started, :sync_progress, :sync_completed, :bad_file_issue_updated] do
    {:noreply,
     if(socket.assigns.loaded_once,
       do: async_load_issues(socket, include_summary: true),
       else: socket
     )}
  end

  @impl true
  def handle_info({_event, _data}, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:load_issues, {:ok, issue_payload}, socket) do
    {:noreply, apply_issue_payload(socket, issue_payload)}
  end

  @impl true
  def handle_async(:load_issues, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:loading_issues, false)
     |> put_flash(:error, "Failed to load bad-file issues")}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    normalized_status = if status in @status_filter_values, do: status, else: "all"

    {:noreply,
     push_patch(socket, to: patch_path(socket.assigns, status: normalized_status, page: 1))}
  end

  @impl true
  def handle_event("filter_service", %{"service" => service}, socket) do
    normalized_service = if service in @service_filter_values, do: service, else: "all"

    {:noreply,
     push_patch(socket, to: patch_path(socket.assigns, service: normalized_service, page: 1))}
  end

  @impl true
  def handle_event("filter_kind", %{"kind" => kind}, socket) do
    normalized_kind = if kind in @kind_filter_values, do: kind, else: "all"
    {:noreply, push_patch(socket, to: patch_path(socket.assigns, kind: normalized_kind, page: 1))}
  end

  @impl true
  def handle_event("search_issues", %{"query" => query}, socket) do
    {:noreply,
     push_patch(socket,
       to: patch_path(socket.assigns, search: normalize_search_query(query), page: 1)
     )}
  end

  @impl true
  def handle_event("enqueue_issue", %{"id" => id_str}, socket) do
    with {:ok, id} <- Parsers.parse_integer_exact(id_str),
         {:ok, issue} <- Media.fetch_bad_file_issue(id),
         {:ok, _queued_issue} <- Media.enqueue_bad_file_issue(issue) do
      {:noreply, socket |> put_flash(:info, "Queued bad-file issue") |> async_load_issues()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed to queue bad-file issue")}
    end
  end

  @impl true
  def handle_event("dismiss_issue", %{"id" => id_str}, socket) do
    with {:ok, id} <- Parsers.parse_integer_exact(id_str),
         {:ok, issue} <- Media.fetch_bad_file_issue(id),
         {:ok, _dismissed_issue} <- Media.dismiss_bad_file_issue(issue) do
      {:noreply, socket |> put_flash(:info, "Dismissed bad-file issue") |> async_load_issues()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed to dismiss bad-file issue")}
    end
  end

  @impl true
  def handle_event("retry_issue", %{"id" => id_str}, socket) do
    with {:ok, id} <- Parsers.parse_integer_exact(id_str),
         {:ok, issue} <- Media.fetch_bad_file_issue(id),
         {:ok, _retried_issue} <- Media.retry_bad_file_issue(issue) do
      {:noreply, socket |> put_flash(:info, "Re-queued bad-file issue") |> async_load_issues()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed to re-queue bad-file issue")}
    end
  end

  @impl true
  def handle_event("replace_issue_now", %{"id" => id_str}, socket) do
    with {:ok, id} <- Parsers.parse_integer_exact(id_str),
         {:ok, issue} <- Media.fetch_bad_file_issue(id),
         {:ok, _issue} <- BadFileRemediation.process_issue(issue, []) do
      {:noreply,
       socket |> put_flash(:info, "Started replacement for selected issue") |> async_load_issues()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed to start replacement")}
    end
  end

  @impl true
  def handle_event("replace_next_queued", _params, socket) do
    case BadFileRemediation.process_next_issue([]) do
      {:ok, _issue} ->
        {:noreply,
         socket
         |> put_flash(:info, "Started replacement for next queued bad file")
         |> async_load_issues()}

      :idle ->
        {:noreply, put_flash(socket, :error, "No queued bad files to replace")}

      _other ->
        {:noreply, put_flash(socket, :error, "Failed to start queued replacement")}
    end
  end

  @impl true
  def handle_event("replace_next_queued_service", %{"service" => service}, socket) do
    case normalize_service(service) do
      :all ->
        {:noreply, put_flash(socket, :error, "Unknown replacement lane")}

      service_type ->
        case BadFileRemediation.process_next_issue(service_type: service_type) do
          {:ok, _issue} ->
            {:noreply,
             socket
             |> put_flash(:info, "Started replacement for next queued #{service} bad file")
             |> async_load_issues()}

          :idle ->
            {:noreply, put_flash(socket, :error, "No queued #{service} bad files to replace")}

          _other ->
            {:noreply, put_flash(socket, :error, "Failed to start queued #{service} replacement")}
        end
    end
  end

  @impl true
  def handle_event("replace_queued_now", _params, socket) do
    results =
      [:sonarr, :sportarr, :radarr]
      |> Enum.map(&BadFileRemediation.process_next_issue(service_type: &1))

    started_count = Enum.count(results, &match?({:ok, _issue}, &1))

    case started_count do
      0 ->
        {:noreply, put_flash(socket, :error, "No queued bad files to replace")}

      count ->
        {:noreply,
         socket
         |> put_flash(:info, "Started replacement for #{count} queued bad files")
         |> async_load_issues()}
    end
  end

  @impl true
  def handle_event("queue_series_issues", %{"id" => id_str}, socket) do
    with {:ok, id} <- Parsers.parse_integer_exact(id_str),
         {:ok, issue} <- Media.fetch_bad_file_issue(id),
         {:ok, count} <- Media.queue_bad_file_issue_series(issue) do
      {:noreply,
       socket
       |> put_flash(:info, "Queued #{count} bad files from this series")
       |> async_load_issues()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed to queue bad files from this series")}
    end
  end

  @impl true
  def handle_event("queue_filtered_issues", _params, socket) do
    case Media.enqueue_bad_file_issues(filtered_active_issues(socket)) do
      {:ok, count} when count > 0 ->
        {:noreply,
         socket
         |> put_flash(:info, "Queued #{count} filtered bad-file issues")
         |> async_load_issues()}

      {:ok, 0} ->
        {:noreply, put_flash(socket, :error, "No filtered bad-file issues could be queued")}
    end
  end

  @impl true
  def handle_event("replace_filtered_now", _params, socket) do
    case Media.enqueue_bad_file_issues(filtered_active_issues(socket)) do
      {:ok, queued_count} when queued_count > 0 ->
        started_count = start_service_replacements()

        {:noreply,
         socket
         |> put_flash(
           :info,
           "Queued #{queued_count} filtered bad-file issues and started #{started_count} replacements"
         )
         |> async_load_issues()}

      {:ok, 0} ->
        {:noreply, put_flash(socket, :error, "No filtered bad-file issues could be queued")}
    end
  end

  @impl true
  def handle_event("toggle_resolved", _params, socket) do
    {:noreply,
     socket |> assign(:show_resolved, !socket.assigns.show_resolved) |> async_load_issues()}
  end

  defp async_load_issues(socket, opts \\ [])
  defp async_load_issues(%{assigns: %{loaded_once: false}} = socket, _opts), do: socket

  defp async_load_issues(socket, opts) do
    if connected?(socket) do
      load_assigns = issue_load_assigns(socket.assigns)
      issue_summary = socket.assigns.issue_summary

      show_loading? = socket.assigns.issues == []

      socket
      |> assign(:loading_issues, show_loading?)
      |> start_async(:load_issues, fn ->
        fetch_issue_payload(
          load_assigns,
          Keyword.merge([include_summary: false, issue_summary: issue_summary], opts)
        )
      end)
    else
      socket
    end
  end

  defp reload_issues_for_params(%{assigns: %{loaded_once: false}} = socket, _changed?) do
    if connected?(socket) do
      load_assigns = issue_load_assigns(socket.assigns)
      start_async(socket, :load_issues, fn -> fetch_issue_payload(load_assigns) end)
    else
      socket
    end
  end

  defp reload_issues_for_params(socket, false), do: socket

  defp reload_issues_for_params(socket, _changed?) do
    socket
    |> apply_issue_payload(
      fetch_issue_payload(issue_load_assigns(socket.assigns),
        include_summary: false,
        issue_summary: socket.assigns.issue_summary
      )
    )
  end

  defp fetch_issue_payload(assigns, opts \\ []) do
    payload = BadFilesState.load(assigns, opts)

    {payload, page} =
      payload
      |> clamped_page_for(assigns)
      |> maybe_reload_page(payload, assigns, opts)

    payload
    |> Map.put(:page, page)
    |> Map.put(:request, assigns)
    |> Map.put(:url_query, bad_files_url_query(%{assigns | page: page}))
  end

  defp apply_issue_payload(socket, %{request: request} = issue_payload) do
    if issue_load_assigns(socket.assigns) == request do
      issue_payload =
        issue_payload
        |> Map.delete(:request)
        |> Map.put(:loading_issues, false)
        |> Map.put(:loaded_once, true)

      assign(socket, issue_payload)
    else
      socket
    end
  end

  defp apply_issue_payload(socket, issue_payload) do
    socket
    |> assign(Map.put(issue_payload, :loading_issues, false))
  end

  defp normalize_search_query(query) when is_binary(query) do
    query
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_search_query(_query), do: ""

  defp parse_params(params) do
    Map.merge(
      %{
        status_filter: valid_param(params, "status", @status_filter_values),
        service_filter: valid_param(params, "service", @service_filter_values),
        kind_filter: valid_param(params, "kind", @kind_filter_values),
        search_query: params |> Map.get("search", "") |> normalize_search_query()
      },
      FlopList.pagination_assigns(params, @default_per_page, @per_page_options)
    )
  end

  defp filters_changed?(assigns, filters) do
    Enum.any?(@param_keys, fn key -> Map.get(assigns, key) != Map.get(filters, key) end)
  end

  defp patch_path(assigns, overrides) do
    query =
      assigns
      |> bad_files_url_query()
      |> Map.merge(url_overrides(overrides))
      |> drop_default_query_values()

    FlopList.patch_with_page("/bad-files", query, page_override(assigns, overrides))
  end

  defp normalize_service("sonarr"), do: :sonarr
  defp normalize_service("sportarr"), do: :sportarr
  defp normalize_service("radarr"), do: :radarr
  defp normalize_service(_service), do: :all

  defp filtered_active_issues(socket) do
    socket.assigns
    |> issue_load_assigns()
    |> BadFilesState.list_active_issues()
  end

  defp start_service_replacements do
    [:sonarr, :sportarr, :radarr]
    |> Enum.map(&BadFileRemediation.process_next_issue(service_type: &1))
    |> Enum.count(&match?({:ok, _issue}, &1))
  end

  defp bad_files_url_query(assigns) do
    %{
      "status" => assigns.status_filter,
      "service" => assigns.service_filter,
      "kind" => assigns.kind_filter,
      "search" => assigns.search_query,
      "per_page" => assigns.per_page
    }
    |> drop_default_query_values()
  end

  defp assign_url_query(socket) do
    assign(socket, :url_query, bad_files_url_query(socket.assigns))
  end

  defp issue_load_assigns(assigns) do
    Map.take(assigns, [
      :page,
      :per_page,
      :status_filter,
      :service_filter,
      :kind_filter,
      :search_query,
      :show_resolved
    ])
  end

  defp valid_param(params, key, allowed) do
    value = Map.get(params, key, "all")
    if value in allowed, do: value, else: "all"
  end

  defp clamped_page_for(payload, assigns) do
    per_page = payload.meta.page_size || assigns.per_page
    total_pages = FlopList.total_pages(payload.active_total, per_page)

    assigns.page
    |> max(1)
    |> min(total_pages)
  end

  defp maybe_reload_page(page, payload, assigns, opts) do
    if page == assigns.page or payload.active_total == 0 do
      {payload, page}
    else
      reloaded_payload = assigns |> Map.put(:page, page) |> BadFilesState.load(opts)
      {reloaded_payload, page}
    end
  end

  defp url_overrides(overrides) do
    Map.new(overrides, fn {key, value} -> {to_string(key), value} end)
  end

  defp page_override(assigns, overrides) do
    overrides
    |> Keyword.get(:page, assigns.page)
    |> Parsers.parse_int(assigns.page)
    |> max(1)
  end

  defp drop_default_query_values(query) do
    Map.reject(query, fn
      {"per_page", value} -> value in [@default_per_page, to_string(@default_per_page)]
      {_key, value} -> value in [nil, "", "all"]
    end)
  end

  @impl true
  def render(assigns), do: ReencodarrWeb.BadFilesComponents.page(assigns)
end
