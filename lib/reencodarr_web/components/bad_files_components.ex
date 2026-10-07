defmodule ReencodarrWeb.BadFilesComponents do
  @moduledoc "Review and replacement workflow for bad files."
  use ReencodarrWeb, :html

  def page(assigns) do
    assigns = assign(assigns, :selection_count, MapSet.size(assigns.selected))

    ~H"""
    <div class="workbench page-stack">
      <ReencodarrWeb.Layouts.issue_tabs active={:bad_files} />
      <.page_header title="Bad Files" subtitle={"#{@active_total} matching issues"} />
      <nav class="workflow-tabs" aria-label="Replacement workflow">
        <.link
          :for={{status, label, count} <- workflow_tabs(@issue_summary)}
          patch={workflow_path(@url_query, status)}
          aria-current={if @status_filter == status, do: "page"}
          class={if @status_filter == status, do: "active"}
        >
          <span>{label}</span><strong>{count}</strong>
        </.link>
      </nav>
      <p :if={@loading_issues} role="status" class="text-[var(--wb-muted)]">loading issues...</p>
      <div class="content-panel p-4 space-y-4">
        <div class="bad-file-filters">
          <form id="bad-files-status-filter" phx-change="filter_status">
            <select name="status" aria-label="Filter by status" data-role="list-filter-select">
              <option
                :for={value <- @status_filter_values}
                value={value}
                selected={value == @status_filter}
              >
                {display_label(value)}
              </option>
            </select>
          </form>
          <form id="bad-files-service-filter" phx-change="filter_service">
            <select name="service" aria-label="Filter by service" data-role="list-filter-select">
              <option
                :for={value <- @service_filter_values}
                value={value}
                selected={value == @service_filter}
              >
                {display_label(value)}
              </option>
            </select>
          </form>
          <form id="bad-files-kind-filter" phx-change="filter_kind">
            <select name="kind" aria-label="Filter by kind" data-role="list-filter-select">
              <option
                :for={value <- @kind_filter_values}
                value={value}
                selected={value == @kind_filter}
              >
                {display_label(value)}
              </option>
            </select>
          </form>
          <form id="bad-files-search-filter" phx-change="search_issues" class="flex-1">
            <input
              id="bad-files-search"
              type="search"
              name="query"
              value={@search_query}
              phx-debounce="350"
              aria-label="Search bad files by path, reason, or note"
              placeholder="Search path, reason, note"
              data-role="list-search-input"
            />
          </form>
        </div>
        <div :if={@selection_count > 0} class="selection-toolbar">
          <strong>{@selection_count} selected</strong>
          <button phx-click="queue_selected" class="workbench-button">Queue selected</button>
          <button
            phx-click="dismiss_selected"
            class="workbench-button"
            data-confirm={"Dismiss #{@selection_count} selected issues?"}
          >Dismiss selected</button>
          <button phx-click="clear_selection" class="section-action">Clear selection</button>
        </div>
        <div :if={@status_filter == "queued"} class="replacement-queue-actions">
          <p>Queued files wait until you start a replacement.</p>
          <button
            id="start-queued-lanes"
            phx-click="replace_queued_now"
            disabled={@replacement_pending}
            class="workbench-button"
          >Start next for each source</button>
        </div>
        <p :if={@replacement_pending} role="status">Sending replacement request…</p>
        <details id="bad-file-actions" phx-mounted={JS.ignore_attributes("open")}>
          <summary class="section-action">More replacement actions</summary>
          <div class="row-action-items mt-3">
            <button
              id="replace-next-queued"
              phx-click="replace_next_queued"
              disabled={@replacement_pending}
              class="workbench-button"
            >Start next queued</button>
            <button
              id="replace-queued-now"
              phx-click="replace_queued_now"
              disabled={@replacement_pending}
              class="workbench-button"
            >Start next for each source</button>
            <button
              :for={service <- ["sonarr", "sportarr", "radarr"]}
              id={"replace-next-#{service}"}
              phx-click="replace_next_queued_service"
              phx-value-service={service}
              disabled={@replacement_pending}
              class="workbench-button"
            >Start next {display_label(service)}</button>
            <button
              id="queue-filtered-issues"
              phx-click="queue_filtered_issues"
              class="workbench-button"
              data-confirm={"Queue all #{@active_total} matching active issues?"}
            >Queue all {@active_total} matching active issues</button>
            <button
              id="replace-filtered-now"
              phx-click="replace_filtered_now"
              disabled={@replacement_pending}
              class="workbench-button"
              data-confirm={"Queue all #{@active_total} matching active issues and start one replacement per source?"}
            >Queue matching issues and start next per source</button>
          </div>
        </details>
      </div>
      <section class="page-stack" aria-label="Matching bad-file issues">
        <.empty_state
          :if={@issues == [] and not @loading_issues}
          title="No matching issues"
          description="Choose another workflow stage or change the filters."
        />
        <.issue
          :for={issue <- @issues}
          issue={issue}
          selected={MapSet.member?(@selected, issue.id)}
          pending={@replacement_pending}
        />
      </section>
      <.flop_pagination
        id="bad-files-flop-pagination"
        meta={@meta}
        base_path="/bad-files"
        query={@url_query}
        mode={:simple}
      />
    </div>
    """
  end

  attr :issue, :map, required: true
  attr :selected, :boolean, required: true
  attr :pending, :boolean, required: true

  defp issue(assigns) do
    ~H"""
    <article id={"bad-file-#{@issue.id}"} class="bad-file-card content-panel">
      <header>
        <input
          :if={@issue.status in [:open, :failed, :queued]}
          type="checkbox"
          checked={@selected}
          phx-click="toggle_select"
          phx-value-id={@issue.id}
          aria-label={"Select #{Path.basename(@issue.video.path)}"}
        />
        <div class="min-w-0 flex-1">
          <h2>{Path.basename(@issue.video.path)}</h2>
          <p>{display_label(@issue.video.service_type)} · {display_label(@issue.issue_kind)}</p>
        </div>
        <span class="issue-status">{display_label(@issue.status)}</span>
      </header>
      <p class="issue-reason">{issue_reason(@issue)}</p>
      <p :if={@issue.manual_note not in [nil, ""]} class="text-[var(--wb-muted)]">
        {@issue.manual_note}
      </p>
      <details id={"bad-file-details-#{@issue.id}"} phx-mounted={JS.ignore_attributes("open")}>
        <summary class="section-action">File and replacement details</summary>
        <div class="page-stack pt-3">
          <p class="full-path">{@issue.video.path}</p>
          <dl class="inspection-facts">
            <div>
              <dt>Classification</dt><dd>{display_label(@issue.classification)}</dd>
            </div>
            <div>
              <dt>Detected</dt><dd>{@issue.inserted_at}</dd>
            </div>
            <div>
              <dt>Last attempt</dt><dd>{@issue.last_attempted_at || "—"}</dd>
            </div>
            <div>
              <dt>Resolved</dt><dd>{@issue.resolved_at || "—"}</dd>
            </div>
            <div :if={@issue.source_audio_codec}>
              <dt>Source audio</dt><dd>
                {@issue.source_audio_codec} · {@issue.source_channels} channels · {@issue.source_layout}
              </dd>
            </div>
            <div :if={@issue.output_audio_codec}>
              <dt>Output audio</dt><dd>
                {@issue.output_audio_codec} · {@issue.output_channels} channels · {@issue.output_layout}
              </dd>
            </div>
          </dl>
          <.link navigate={~p"/videos?#{%{video: @issue.video_id}}"} class="section-action">Inspect video</.link>
        </div>
      </details>
      <footer>
        <button
          :if={@issue.status in [:open, :failed]}
          id={"enqueue-issue-#{@issue.id}"}
          phx-click="enqueue_issue"
          phx-value-id={@issue.id}
          class="workbench-button"
        >Queue replacement</button>
        <button
          :if={@issue.status in [:open, :failed, :queued]}
          id={"replace-issue-now-#{@issue.id}"}
          phx-click="replace_issue_now"
          phx-value-id={@issue.id}
          disabled={@pending}
          class="workbench-button"
          data-confirm="Start replacement of this file through its source?"
        >Start replacement</button>
        <button
          :if={
            @issue.status in [:open, :failed] and @issue.video.service_type in [:sonarr, :sportarr]
          }
          id={"queue-series-issues-#{@issue.id}"}
          phx-click="queue_series_issues"
          phx-value-id={@issue.id}
          data-confirm="Queue all bad-file issues from this series?"
          class="section-action"
        >Queue series issues</button>
        <button
          :if={@issue.status == :failed}
          id={"retry-issue-#{@issue.id}"}
          phx-click="retry_issue"
          phx-value-id={@issue.id}
          class="section-action"
        >Requeue</button>
        <button
          :if={@issue.status in [:open, :failed, :queued]}
          id={"dismiss-issue-#{@issue.id}"}
          phx-click="dismiss_issue"
          phx-value-id={@issue.id}
          class="section-action"
        >Dismiss</button>
        <p
          :if={@issue.status in [:processing, :waiting_for_replacement]}
          class="text-[var(--wb-muted)]"
        >
          Waiting for the source to import a replacement. The next sync checks the file.
        </p>
      </footer>
    </article>
    """
  end

  defp workflow_tabs(s),
    do: [
      {"all", "All active",
       s.open + s.failed + s.queued + s.processing + s.waiting_for_replacement},
      {"review", "Review", s.open + s.failed},
      {"queued", "Queued", s.queued},
      {"replacing", "Replacing", s.processing + s.waiting_for_replacement},
      {"resolved", "Resolved", s.resolved}
    ]

  defp workflow_path(query, status), do: ~p"/bad-files?#{Map.put(query, "status", status)}"
  defp issue_reason(%{manual_reason: reason}) when reason not in [nil, ""], do: reason
  defp issue_reason(issue), do: display_label(issue.classification)
  defp display_label(value), do: value |> to_string() |> Phoenix.Naming.humanize()
end
