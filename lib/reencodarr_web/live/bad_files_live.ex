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
  @service_filter_values ["all", "sonarr", "radarr"]
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
    {:noreply, if(socket.assigns.loaded_once, do: async_load_issues(socket), else: socket)}
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
      [:sonarr, :radarr]
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

  defp async_load_issues(%{assigns: %{loaded_once: false}} = socket), do: socket

  defp async_load_issues(socket) do
    if connected?(socket) do
      load_assigns = issue_load_assigns(socket.assigns)

      show_loading? = socket.assigns.issues == []

      socket
      |> assign(:loading_issues, show_loading?)
      |> start_async(:load_issues, fn -> fetch_issue_payload(load_assigns) end)
    else
      socket
    end
  end

  defp reload_issues_for_params(%{assigns: %{loaded_once: false}} = socket, _changed?) do
    socket
    |> apply_issue_payload(fetch_issue_payload(issue_load_assigns(socket.assigns)))
    |> assign(:loaded_once, true)
  end

  defp reload_issues_for_params(socket, false), do: socket

  defp reload_issues_for_params(socket, _changed?) do
    socket
    |> apply_issue_payload(fetch_issue_payload(issue_load_assigns(socket.assigns)))
  end

  defp fetch_issue_payload(assigns) do
    payload = BadFilesState.load(assigns)

    {payload, page} =
      payload
      |> clamped_page_for(assigns)
      |> maybe_reload_page(payload, assigns)

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

      assign(socket, issue_payload)
    else
      assign(socket, :loading_issues, false)
    end
  end

  defp apply_issue_payload(socket, issue_payload) do
    socket
    |> assign(Map.put(issue_payload, :loading_issues, false))
  end

  defp issue_reason(issue) do
    case issue.manual_reason do
      nil -> to_string(issue.classification)
      "" -> to_string(issue.classification)
      manual_reason -> manual_reason
    end
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
  defp normalize_service("radarr"), do: :radarr
  defp normalize_service(_service), do: :all

  defp filtered_active_issues(socket) do
    socket.assigns
    |> issue_load_assigns()
    |> BadFilesState.list_active_issues()
  end

  defp filtered_active_total(assigns), do: assigns.active_total || 0

  defp start_service_replacements do
    [:sonarr, :radarr]
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

  defp maybe_reload_page(page, payload, assigns) do
    if page == assigns.page or payload.active_total == 0 do
      {payload, page}
    else
      reloaded_payload = assigns |> Map.put(:page, page) |> BadFilesState.load()
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

  attr :status_filter_values, :list, required: true
  attr :service_filter_values, :list, required: true
  attr :kind_filter_values, :list, required: true
  attr :status_filter, :string, required: true
  attr :service_filter, :string, required: true
  attr :kind_filter, :string, required: true
  attr :search_query, :string, required: true
  attr :active_total, :integer, default: 0

  defp bad_files_toolbar(assigns) do
    ~H"""
    <div class="flex gap-3">
      <div class="flex items-center text-xs text-gray-400">
        Bulk actions apply to all {@active_total} matching active issues.
      </div>
      <button
        id="replace-next-queued"
        phx-click="replace_next_queued"
        class="rounded bg-emerald-700 px-3 py-2 text-sm font-medium text-white hover:bg-emerald-600"
      >
        replace next queued
      </button>
      <button
        id="replace-queued-now"
        phx-click="replace_queued_now"
        class="rounded bg-cyan-700 px-3 py-2 text-sm font-medium text-white hover:bg-cyan-600"
      >
        replace queued now
      </button>
      <button
        id="replace-next-sonarr"
        phx-click="replace_next_queued_service"
        phx-value-service="sonarr"
        class="rounded bg-sky-700 px-3 py-2 text-sm font-medium text-white hover:bg-sky-600"
      >
        replace next sonarr
      </button>
      <button
        id="replace-next-radarr"
        phx-click="replace_next_queued_service"
        phx-value-service="radarr"
        class="rounded bg-violet-700 px-3 py-2 text-sm font-medium text-white hover:bg-violet-600"
      >
        replace next radarr
      </button>
      <button
        id="queue-filtered-issues"
        phx-click="queue_filtered_issues"
        class="rounded bg-amber-700 px-3 py-2 text-sm font-medium text-white hover:bg-amber-600"
      >
        queue all {@active_total} matching active issues
      </button>
      <button
        id="replace-filtered-now"
        phx-click="replace_filtered_now"
        class="rounded bg-orange-700 px-3 py-2 text-sm font-medium text-white hover:bg-orange-600"
      >
        replace all {@active_total} matching active issues now
      </button>
      <form id="bad-files-status-filter" phx-change="filter_status">
        <select
          name="status"
          aria-label="Filter by status"
          class="rounded border border-gray-600 bg-gray-800 px-3 py-2 text-sm text-white"
          data-role="list-filter-select"
        >
          <%= for value <- @status_filter_values do %>
            <option value={value} selected={value == @status_filter}>{value}</option>
          <% end %>
        </select>
      </form>
      <form id="bad-files-service-filter" phx-change="filter_service">
        <select
          name="service"
          aria-label="Filter by service"
          class="rounded border border-gray-600 bg-gray-800 px-3 py-2 text-sm text-white"
          data-role="list-filter-select"
        >
          <%= for value <- @service_filter_values do %>
            <option value={value} selected={value == @service_filter}>{value}</option>
          <% end %>
        </select>
      </form>
      <form id="bad-files-kind-filter" phx-change="filter_kind">
        <select
          name="kind"
          aria-label="Filter by kind"
          class="rounded border border-gray-600 bg-gray-800 px-3 py-2 text-sm text-white"
          data-role="list-filter-select"
        >
          <%= for value <- @kind_filter_values do %>
            <option value={value} selected={value == @kind_filter}>{value}</option>
          <% end %>
        </select>
      </form>
      <form id="bad-files-search-filter" phx-change="search_issues" class="flex-1">
        <input
          id="bad-files-search"
          type="search"
          name="query"
          value={@search_query}
          aria-label="Search bad files by path, reason, or note"
          placeholder="search path, reason, note"
          class="w-full rounded border border-gray-600 bg-gray-800 px-3 py-2 text-sm text-white placeholder:text-gray-500"
          data-role="list-search-input"
        />
      </form>
    </div>
    """
  end

  attr :issue_summary, :map, required: true

  defp bad_files_summary(assigns) do
    ~H"""
    <div class="grid gap-3 md:grid-cols-6">
      <div class="rounded border border-gray-700 bg-gray-800 p-3 text-sm text-gray-300">
        Open: {@issue_summary.open}
      </div>
      <div class="rounded border border-gray-700 bg-gray-800 p-3 text-sm text-gray-300">
        Queued: {@issue_summary.queued}
      </div>
      <div class="rounded border border-gray-700 bg-gray-800 p-3 text-sm text-gray-300">
        Processing: {@issue_summary.processing}
      </div>
      <div class="rounded border border-gray-700 bg-gray-800 p-3 text-sm text-gray-300">
        Waiting: {@issue_summary.waiting_for_replacement}
      </div>
      <div class="rounded border border-gray-700 bg-gray-800 p-3 text-sm text-gray-300">
        Failed: {@issue_summary.failed}
      </div>
      <div class="rounded border border-gray-700 bg-gray-800 p-3 text-sm text-gray-300">
        Resolved: {@issue_summary.resolved}
      </div>
    </div>
    """
  end

  attr :replacement_issues, :list, required: true

  defp active_replacements(assigns) do
    ~H"""
    <%= if @replacement_issues != [] do %>
      <section class="space-y-2">
        <h2 class="text-lg font-semibold text-white">Active Replacements</h2>
        <div class="grid gap-3 md:grid-cols-2">
          <%= for issue <- @replacement_issues do %>
            <div class="rounded border border-emerald-700/60 bg-emerald-950/30 p-3 text-sm text-emerald-100">
              <div class="font-medium">{Path.basename(issue.video.path)}</div>
              <div class="mt-1 text-xs uppercase tracking-wide text-emerald-300">
                {issue.video.service_type} • {issue.status}
              </div>
              <div class="mt-1 text-xs text-emerald-200/80">{issue_reason(issue)}</div>
            </div>
          <% end %>
        </div>
      </section>
    <% end %>
    """
  end

  attr :title, :string, required: true
  attr :issues, :list, required: true
  attr :meta, Flop.Meta, default: nil
  attr :url_query, :map, default: %{}
  attr :paginate?, :boolean, default: false

  defp bad_files_issue_table(assigns) do
    ~H"""
    <section class="space-y-2">
      <h2 class="text-lg font-semibold text-white">{@title}</h2>
      <div class="bg-gray-800 rounded-lg border border-gray-700 overflow-hidden">
        <table class="min-w-full divide-y divide-gray-700 text-sm">
          <thead class="bg-gray-700/80">
            <tr>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-300 uppercase tracking-wider">
                File
              </th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-300 uppercase tracking-wider">
                Reason
              </th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-300 uppercase tracking-wider">
                Status
              </th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-300 uppercase tracking-wider">
                Actions
              </th>
            </tr>
          </thead>
          <.render_issue_rows issues={@issues} />
        </table>
      </div>
      <.flop_pagination
        :if={@paginate?}
        id="bad-files-flop-pagination"
        meta={@meta}
        base_path="/bad-files"
        query={@url_query}
        mode={:simple}
      />
    </section>
    """
  end

  attr :show_resolved, :boolean, required: true
  attr :issues, :list, required: true

  defp resolved_issues_section(assigns) do
    ~H"""
    <section class="space-y-2">
      <h2 class="text-lg font-semibold text-white">Resolved Issues</h2>
      <div class="flex items-center justify-between">
        <p class="text-sm text-gray-400">Recent resolved issues are loaded on demand.</p>
        <button
          id="toggle-resolved-issues"
          phx-click="toggle_resolved"
          class="rounded bg-gray-700 px-3 py-2 text-sm font-medium text-white hover:bg-gray-600"
        >
          <%= if @show_resolved do %>
            hide resolved
          <% else %>
            show resolved
          <% end %>
        </button>
      </div>
      <.bad_files_issue_table :if={@show_resolved} title="Resolved Issues" issues={@issues} />
    </section>
    """
  end

  attr :issues, :list, required: true

  defp render_issue_rows(assigns) do
    ~H"""
    <tbody class="divide-y divide-gray-600">
      <%= for issue <- @issues do %>
        <tr>
          <td class="px-4 py-3 text-gray-200">
            <div>{Path.basename(issue.video.path)}</div>
            <div class="text-xs text-gray-500">{issue.video.service_type}</div>
          </td>
          <td class="px-4 py-3 text-gray-300">
            <div>{issue_reason(issue)}</div>
            <div class="text-xs text-gray-500">{issue.issue_kind}</div>
            <%= if issue.manual_note && issue.manual_note != "" do %>
              <div class="text-xs text-gray-500">{issue.manual_note}</div>
            <% end %>
          </td>
          <td class="px-4 py-3 text-gray-300">{issue.status}</td>
          <td class="px-4 py-3">
            <div class="flex gap-2">
              <button
                :if={issue.status in [:open, :failed]}
                id={"replace-issue-now-#{issue.id}"}
                phx-click="replace_issue_now"
                phx-value-id={issue.id}
                class="text-amber-300 hover:text-amber-200 text-xs"
              >
                replace now
              </button>
              <button
                :if={issue.status in [:open, :failed]}
                id={"enqueue-issue-#{issue.id}"}
                phx-click="enqueue_issue"
                phx-value-id={issue.id}
                class="text-emerald-300 hover:text-emerald-200 text-xs"
              >
                queue
              </button>
              <button
                :if={issue.video.service_type == :sonarr and issue.status in [:open, :failed]}
                id={"queue-series-issues-#{issue.id}"}
                phx-click="queue_series_issues"
                phx-value-id={issue.id}
                class="text-cyan-300 hover:text-cyan-200 text-xs"
              >
                queue series bad
              </button>
              <button
                :if={issue.status == :failed}
                id={"retry-issue-#{issue.id}"}
                phx-click="retry_issue"
                phx-value-id={issue.id}
                class="text-blue-300 hover:text-blue-200 text-xs"
              >
                retry
              </button>
              <button
                :if={issue.status != :dismissed}
                id={"dismiss-issue-#{issue.id}"}
                phx-click="dismiss_issue"
                phx-value-id={issue.id}
                class="text-red-300 hover:text-red-200 text-xs"
              >
                dismiss
              </button>
            </div>
          </td>
        </tr>
      <% end %>
      <%= if @issues == [] do %>
        <tr>
          <td colspan="4" class="px-6 py-10 text-center text-gray-500">
            No bad-file issues tracked.
          </td>
        </tr>
      <% end %>
    </tbody>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-900 p-6">
      <div class="max-w-6xl mx-auto space-y-4">
        <div>
          <h1 class="text-3xl font-bold text-white">Bad Files</h1>
          <p :if={@loading_issues} class="text-gray-400">loading issues...</p>
          <p :if={not @loading_issues} class="text-gray-400">{@tracked_count} tracked</p>
        </div>

        <.bad_files_summary issue_summary={@issue_summary} />
        <.active_replacements replacement_issues={@replacement_issues} />
        <.bad_files_toolbar
          status_filter_values={@status_filter_values}
          service_filter_values={@service_filter_values}
          kind_filter_values={@kind_filter_values}
          status_filter={@status_filter}
          service_filter={@service_filter}
          kind_filter={@kind_filter}
          search_query={@search_query}
          active_total={filtered_active_total(assigns)}
        />
        <.bad_files_issue_table
          title={if @status_filter == "resolved", do: "Resolved Issues", else: "Active Issues"}
          issues={@active_issues}
          meta={@meta}
          url_query={@url_query}
          paginate?
        />
        <.resolved_issues_section
          :if={@status_filter != "resolved"}
          show_resolved={@show_resolved}
          issues={@resolved_issues}
        />
      </div>
    </div>
    """
  end
end
