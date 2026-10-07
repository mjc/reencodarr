defmodule ReencodarrWeb.BadFilesComponents do
  @moduledoc "Bad-file queues, replacements, and issue rows."
  use ReencodarrWeb, :html

  defp issue_reason(issue) do
    case issue.manual_reason do
      nil -> to_string(issue.classification)
      "" -> to_string(issue.classification)
      manual_reason -> manual_reason
    end
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
    <div class="content-panel p-4 space-y-4">
      <div class="bad-file-filters">
        <form id="bad-files-status-filter" phx-change="filter_status" phx-no-unused-field>
          <select
            name="status"
            aria-label="Filter by status"
            class="rounded border border-[var(--wb-line)] bg-[var(--wb-panel)] px-3 py-2 text-sm text-[var(--wb-text)]"
            data-role="list-filter-select"
          >
            <%= for value <- @status_filter_values do %>
              <option value={value} selected={value == @status_filter}>{value}</option>
            <% end %>
          </select>
        </form>
        <form id="bad-files-service-filter" phx-change="filter_service" phx-no-unused-field>
          <select
            name="service"
            aria-label="Filter by service"
            class="rounded border border-[var(--wb-line)] bg-[var(--wb-panel)] px-3 py-2 text-sm text-[var(--wb-text)]"
            data-role="list-filter-select"
          >
            <%= for value <- @service_filter_values do %>
              <option value={value} selected={value == @service_filter}>{value}</option>
            <% end %>
          </select>
        </form>
        <form id="bad-files-kind-filter" phx-change="filter_kind" phx-no-unused-field>
          <select
            name="kind"
            aria-label="Filter by kind"
            class="rounded border border-[var(--wb-line)] bg-[var(--wb-panel)] px-3 py-2 text-sm text-[var(--wb-text)]"
            data-role="list-filter-select"
          >
            <%= for value <- @kind_filter_values do %>
              <option value={value} selected={value == @kind_filter}>{value}</option>
            <% end %>
          </select>
        </form>
        <form
          id="bad-files-search-filter"
          phx-change="search_issues"
          phx-no-unused-field
          class="flex-1"
        >
          <input
            id="bad-files-search"
            type="search"
            name="query"
            value={@search_query}
            aria-label="Search bad files by path, reason, or note"
            placeholder="search path, reason, note"
            class="w-full rounded border border-[var(--wb-line)] bg-[var(--wb-panel)] px-3 py-2 text-sm text-[var(--wb-text)] placeholder:text-[var(--wb-muted)]"
            data-role="list-search-input"
          />
        </form>
      </div>
      <details id="bad-file-actions" phx-mounted={JS.ignore_attributes("open")}>
        <summary class="workbench-button">Replacement actions</summary>
        <div class="space-y-3 pt-4">
          <div class="flex items-center text-xs text-[var(--wb-muted)]">
            Bulk actions apply to all {@active_total} matching active issues.
          </div>
          <div class="flex flex-wrap gap-2">
            <button
              id="replace-next-queued"
              phx-click="replace_next_queued"
              class="workbench-button"
            >
              replace next queued
            </button>
            <button
              id="replace-queued-now"
              phx-click="replace_queued_now"
              class="workbench-button"
            >
              replace queued now
            </button>
            <button
              id="replace-next-sonarr"
              phx-click="replace_next_queued_service"
              phx-value-service="sonarr"
              class="workbench-button"
            >
              replace next sonarr
            </button>
            <button
              id="replace-next-radarr"
              phx-click="replace_next_queued_service"
              phx-value-service="radarr"
              class="workbench-button"
            >
              replace next radarr
            </button>
            <button
              id="queue-filtered-issues"
              phx-click="queue_filtered_issues"
              class="workbench-button"
            >
              queue all {@active_total} matching active issues
            </button>
            <button
              id="replace-filtered-now"
              phx-click="replace_filtered_now"
              class="workbench-button"
            >
              replace all {@active_total} matching active issues now
            </button>
          </div>
        </div>
      </details>
    </div>
    """
  end

  attr :issue_summary, :map, required: true

  defp bad_files_summary(assigns) do
    ~H"""
    <div class="issue-counts">
      <div class="rounded border border-[var(--wb-line)] bg-[var(--wb-panel)] p-3 text-sm text-[var(--wb-muted)]">
        Open: {@issue_summary.open}
      </div>
      <div class="rounded border border-[var(--wb-line)] bg-[var(--wb-panel)] p-3 text-sm text-[var(--wb-muted)]">
        Queued: {@issue_summary.queued}
      </div>
      <div class="rounded border border-[var(--wb-line)] bg-[var(--wb-panel)] p-3 text-sm text-[var(--wb-muted)]">
        Processing: {@issue_summary.processing}
      </div>
      <div class="rounded border border-[var(--wb-line)] bg-[var(--wb-panel)] p-3 text-sm text-[var(--wb-muted)]">
        Waiting: {@issue_summary.waiting_for_replacement}
      </div>
      <div class="rounded border border-[var(--wb-line)] bg-[var(--wb-panel)] p-3 text-sm text-[var(--wb-muted)]">
        Failed: {@issue_summary.failed}
      </div>
      <div class="rounded border border-[var(--wb-line)] bg-[var(--wb-panel)] p-3 text-sm text-[var(--wb-muted)]">
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
        <h2 class="text-lg font-semibold text-[var(--wb-text)]">Active Replacements</h2>
        <div class="grid gap-3 md:grid-cols-2">
          <%= for issue <- @replacement_issues do %>
            <div class="rounded border border-emerald-700/60 bg-emerald-950/30 p-3 text-sm text-emerald-100">
              <div class="font-medium">{Path.basename(issue.video.path)}</div>
              <div class="mt-1 text-xs normal-case tracking-normal text-emerald-300">
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
      <h2 class="text-lg font-semibold text-[var(--wb-text)]">{@title}</h2>
      <div class="bg-[var(--wb-panel)] rounded-md border border-[var(--wb-line)] overflow-x-auto">
        <table class="bad-files-table min-w-full divide-y divide-[var(--wb-line)] text-sm">
          <thead class="bg-[var(--wb-raised)]">
            <tr>
              <th class="px-4 py-3 text-left text-xs font-medium text-[var(--wb-muted)] normal-case tracking-normal">
                File
              </th>
              <th class="px-4 py-3 text-left text-xs font-medium text-[var(--wb-muted)] normal-case tracking-normal">
                Reason
              </th>
              <th class="px-4 py-3 text-left text-xs font-medium text-[var(--wb-muted)] normal-case tracking-normal">
                Status
              </th>
              <th class="px-4 py-3 text-left text-xs font-medium text-[var(--wb-muted)] normal-case tracking-normal">
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
      <h2 class="text-lg font-semibold text-[var(--wb-text)]">Resolved Issues</h2>
      <div class="flex flex-wrap gap-3 items-center justify-between">
        <p class="text-sm text-[var(--wb-muted)]">Recent resolved issues are loaded on demand.</p>
        <button
          id="toggle-resolved-issues"
          phx-click="toggle_resolved"
          class="rounded bg-[var(--wb-raised)] px-3 py-2 text-sm font-medium text-[var(--wb-text)] hover:bg-[var(--wb-raised)]"
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
    <tbody class="divide-y divide-[var(--wb-line)]">
      <%= for issue <- @issues do %>
        <tr>
          <td class="px-4 py-3 text-[var(--wb-text)]">
            <div>{Path.basename(issue.video.path)}</div>
            <div class="text-xs text-[var(--wb-muted)]">{issue.video.service_type}</div>
          </td>
          <td class="px-4 py-3 text-[var(--wb-muted)]">
            <div>{issue_reason(issue)}</div>
            <div class="text-xs text-[var(--wb-muted)]">{issue.issue_kind}</div>
            <%= if issue.manual_note && issue.manual_note != "" do %>
              <div class="text-xs text-[var(--wb-muted)]">{issue.manual_note}</div>
            <% end %>
          </td>
          <td class="px-4 py-3 text-[var(--wb-muted)]">{issue.status}</td>
          <td class="px-4 py-3">
            <div class="flex gap-2">
              <button
                :if={issue.status in [:open, :failed]}
                id={"replace-issue-now-#{issue.id}"}
                phx-click="replace_issue_now"
                phx-value-id={issue.id}
                class="text-[var(--wb-amber)] hover:text-amber-200 text-xs"
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
                :if={
                  issue.video.service_type in [:sonarr, :sportarr] and
                    issue.status in [:open, :failed]
                }
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
          <td colspan="4" class="px-6 py-10 text-center text-[var(--wb-muted)]">
            No bad-file issues tracked.
          </td>
        </tr>
      <% end %>
    </tbody>
    """
  end

  def page(assigns) do
    ~H"""
    <div class="workbench page-stack">
      <div class="page-stack">
        <ReencodarrWeb.Layouts.issue_tabs active={:bad_files} />
        <div>
          <h1>Bad Files</h1>
          <p :if={@loading_issues} class="text-[var(--wb-muted)]">loading issues...</p>
          <p :if={not @loading_issues} class="text-[var(--wb-muted)]">{@tracked_count} tracked</p>
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
          active_total={@active_total}
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
