defmodule ReencodarrWeb.BadFilesLive do
  use ReencodarrWeb, :live_view

  alias Reencodarr.BadFileRemediation
  alias Reencodarr.BadFiles.State, as: BadFilesState
  alias Reencodarr.Core.Parsers
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Media
  alias Reencodarr.Media.BadFileIssue
  alias ReencodarrWeb.Live.ListPagination

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
  @active_statuses [:open, :queued, :processing, :waiting_for_replacement, :failed]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())
      Process.send_after(self(), :periodic_update, @update_interval)
      send(self(), :load_initial_data)
    end

    {:ok,
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
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = parse_params(params)

    socket =
      socket
      |> assign(filters)
      |> then(fn s ->
        if connected?(s) and s.assigns.loaded_once, do: async_load_issues(s), else: s
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_info(:load_initial_data, socket) do
    {:noreply, socket |> assign(:loaded_once, true) |> async_load_issues()}
  end

  @impl true
  def handle_info(:periodic_update, socket) do
    Process.send_after(self(), :periodic_update, @update_interval)
    {:noreply, if(socket.assigns.loaded_once, do: async_load_issues(socket), else: socket)}
  end

  @impl true
  def handle_info({event, _data}, socket)
      when event in [:sync_started, :sync_progress, :sync_completed] do
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
  def handle_event("set_per_page", %{"per_page" => n}, socket) do
    per_page = Parsers.parse_int(n, @default_per_page)
    per_page = if per_page in @per_page_options, do: per_page, else: @default_per_page
    {:noreply, push_patch(socket, to: patch_path(socket.assigns, per_page: per_page, page: 1))}
  end

  @impl true
  def handle_event("prev_page", _params, socket) do
    if socket.assigns.page > 1 do
      {:noreply,
       push_patch(socket, to: patch_path(socket.assigns, page: socket.assigns.page - 1))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("next_page", _params, socket) do
    if socket.assigns.page < max_page(socket.assigns.active_total, socket.assigns.per_page) do
      {:noreply,
       push_patch(socket, to: patch_path(socket.assigns, page: socket.assigns.page + 1))}
    else
      {:noreply, socket}
    end
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

  defp async_load_issues(socket) do
    load_assigns = %{
      page: socket.assigns.page,
      per_page: socket.assigns.per_page,
      status_filter: socket.assigns.status_filter,
      service_filter: socket.assigns.service_filter,
      kind_filter: socket.assigns.kind_filter,
      search_query: socket.assigns.search_query,
      show_resolved: socket.assigns.show_resolved
    }

    socket
    |> assign(:loading_issues, true)
    |> start_async(:load_issues, fn -> fetch_issue_payload(load_assigns) end)
  end

  defp fetch_issue_payload(assigns) do
    BadFilesState.load(assigns)
  end

  defp apply_issue_payload(socket, issue_payload) do
    assign(socket, Map.put(issue_payload, :loading_issues, false))
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
    %{
      status_filter:
        params
        |> Map.get("status", "all")
        |> then(&if(&1 in @status_filter_values, do: &1, else: "all")),
      service_filter:
        params
        |> Map.get("service", "all")
        |> then(&if(&1 in @service_filter_values, do: &1, else: "all")),
      kind_filter:
        params
        |> Map.get("kind", "all")
        |> then(&if(&1 in @kind_filter_values, do: &1, else: "all")),
      search_query: params |> Map.get("search", "") |> normalize_search_query(),
      page: params |> Map.get("page", "1") |> Parsers.parse_int(1) |> max(1),
      per_page:
        params
        |> Map.get("per_page", "#{@default_per_page}")
        |> Parsers.parse_int(@default_per_page)
        |> then(&if(&1 in @per_page_options, do: &1, else: @default_per_page))
    }
  end

  defp patch_path(assigns, overrides) do
    overrides_map = Enum.into(overrides, %{}, fn {k, v} -> {to_string(k), v} end)

    query =
      %{
        "status" => assigns.status_filter,
        "service" => assigns.service_filter,
        "kind" => assigns.kind_filter,
        "search" => assigns.search_query,
        "page" => assigns.page,
        "per_page" => assigns.per_page
      }
      |> Map.merge(overrides_map)
      |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" or v == "all" end)
      |> Enum.map(fn {k, v} -> {k, to_string(v)} end)
      |> URI.encode_query()

    case query do
      "" -> "/bad-files"
      _ -> "/bad-files?#{query}"
    end
  end

  defp normalize_service("sonarr"), do: :sonarr
  defp normalize_service("radarr"), do: :radarr
  defp normalize_service(_service), do: :all

  defp filtered_active_issues(socket) do
    filters = [
      service: socket.assigns.service_filter,
      kind: socket.assigns.kind_filter,
      search: socket.assigns.search_query,
      statuses: active_statuses_for_filter(socket.assigns.status_filter)
    ]

    case Keyword.get(filters, :statuses) do
      [] -> []
      _statuses -> Media.list_bad_file_issues(filters)
    end
  end

  defp active_statuses_for_filter(status_filter) do
    case status_filter do
      "all" -> @active_statuses
      "resolved" -> []
      other -> [String.to_existing_atom(other)]
    end
  rescue
    ArgumentError -> @active_statuses
  end

  defp start_service_replacements do
    [:sonarr, :radarr]
    |> Enum.map(&BadFileRemediation.process_next_issue(service_type: &1))
    |> Enum.count(&match?({:ok, _issue}, &1))
  end

  defp max_page(total, per_page), do: ListPagination.max_page(total, per_page)

  defp pagination_label(page, per_page, total),
    do: ListPagination.pagination_label(page, per_page, total)

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

        <div class="flex gap-3">
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
            queue filtered
          </button>
          <button
            id="replace-filtered-now"
            phx-click="replace_filtered_now"
            class="rounded bg-orange-700 px-3 py-2 text-sm font-medium text-white hover:bg-orange-600"
          >
            replace filtered now
          </button>
          <form id="bad-files-status-filter" phx-change="filter_status">
            <select
              name="status"
              value={@status_filter}
              class="rounded border border-gray-600 bg-gray-800 px-3 py-2 text-sm text-white"
            >
              <%= for status <- @status_filter_values do %>
                <option value={status}>{status}</option>
              <% end %>
            </select>
          </form>
          <form id="bad-files-service-filter" phx-change="filter_service">
            <select
              name="service"
              value={@service_filter}
              class="rounded border border-gray-600 bg-gray-800 px-3 py-2 text-sm text-white"
            >
              <%= for service <- @service_filter_values do %>
                <option value={service}>{service}</option>
              <% end %>
            </select>
          </form>
          <form id="bad-files-kind-filter" phx-change="filter_kind">
            <select
              name="kind"
              value={@kind_filter}
              class="rounded border border-gray-600 bg-gray-800 px-3 py-2 text-sm text-white"
            >
              <%= for kind <- @kind_filter_values do %>
                <option value={kind}>{kind}</option>
              <% end %>
            </select>
          </form>
          <form id="bad-files-search-filter" phx-change="search_issues" class="flex-1">
            <input
              type="text"
              name="query"
              value={@search_query}
              placeholder="search path, reason, note"
              class="w-full rounded border border-gray-600 bg-gray-800 px-3 py-2 text-sm text-white placeholder:text-gray-500"
            />
          </form>
        </div>

        <section class="space-y-2">
          <h2 class="text-lg font-semibold text-white">Active Issues</h2>
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
              <.render_issue_rows issues={@active_issues} />
            </table>
          </div>
          <div class="flex items-center justify-between text-sm text-gray-400">
            <span>{pagination_label(@page, @per_page, @active_total)}</span>
            <div class="flex items-center gap-2">
              <form phx-change="set_per_page">
                <select
                  name="per_page"
                  value={@per_page}
                  class="rounded border border-gray-600 bg-gray-800 px-3 py-2 text-sm text-white"
                >
                  <%= for n <- @per_page_options do %>
                    <option value={n}>{n} / page</option>
                  <% end %>
                </select>
              </form>
              <button
                phx-click="prev_page"
                disabled={@page <= 1}
                class="px-3 py-1 bg-gray-700 rounded text-gray-300 hover:bg-gray-600 disabled:opacity-40 disabled:cursor-not-allowed"
              >
                Previous
              </button>
              <span class="px-3 py-1">{@page} / {max_page(@active_total, @per_page)}</span>
              <button
                phx-click="next_page"
                disabled={@page >= max_page(@active_total, @per_page)}
                class="px-3 py-1 bg-gray-700 rounded text-gray-300 hover:bg-gray-600 disabled:opacity-40 disabled:cursor-not-allowed"
              >
                Next
              </button>
            </div>
          </div>
        </section>

        <section class="space-y-2">
          <h2 class="text-lg font-semibold text-white">Resolved Issues</h2>
          <div class="flex items-center justify-between">
            <p class="text-sm text-gray-400">
              Recent resolved issues are loaded on demand.
            </p>
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
          <%= if @show_resolved do %>
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
                <.render_issue_rows issues={@resolved_issues} />
              </table>
            </div>
          <% end %>
        </section>
      </div>
    </div>
    """
  end
end
