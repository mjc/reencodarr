defmodule ReencodarrWeb.BadFilesComponents do
  @moduledoc "Review and replacement workflow for bad files."
  use ReencodarrWeb, :html

  def page(assigns) do
    assigns = assign(assigns, :selection_count, MapSet.size(assigns.selected))

    ~H"""
    <div class="workbench page-stack">
      <ReencodarrWeb.Layouts.issue_tabs active={:bad_files} />
      <.page_header title="Bad files" subtitle={"#{@active_total} matching issues"} />
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
      <div class="content-panel p-4 space-y-4">
        <div class="filter-fields">
          <form id="bad-files-status-filter" phx-change="filter_status" phx-submit="filter_status">
            <.select_field
              id="bad-files-status"
              name="status"
              label="Status"
              value={@status_filter}
              options={filter_options(@status_filter_values)}
            />
          </form>
          <form id="bad-files-service-filter" phx-change="filter_service" phx-submit="filter_service">
            <.select_field
              id="bad-files-source"
              name="service"
              label="Source"
              value={@service_filter}
              options={filter_options(@service_filter_values)}
            />
          </form>
          <form id="bad-files-kind-filter" phx-change="filter_kind" phx-submit="filter_kind">
            <.select_field
              id="bad-files-kind"
              name="kind"
              label="Kind"
              value={@kind_filter}
              options={filter_options(@kind_filter_values)}
            />
          </form>
          <form
            id="bad-files-search-filter"
            phx-change="search_issues"
            phx-submit="search_issues"
            class="filter-search"
          >
            <.search_field
              id="bad-files-search"
              name="query"
              label="Search files"
              value={@search_query}
              phx-debounce="350"
              placeholder="Search path, reason, note"
            />
          </form>
        </div>
        <.selection_bar count={@selection_count} on_clear="clear_selection">
          <button type="button" phx-click="queue_selected" class="workbench-button">Queue selected</button>
          <button
            phx-click="dismiss_selected"
            class="workbench-button"
            data-confirm={"Dismiss #{@selection_count} selected issues?"}
          >Dismiss selected</button>
        </.selection_bar>
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
      <.list_results loading={@loading_issues} empty={@issues == []} label="issues">
        <div class="page-stack">
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
        </div>
        <.flop_pagination
          id="bad-files-flop-pagination"
          meta={@meta}
          base_path="/bad-files"
          query={@url_query}
          mode={:simple}
        />
      </.list_results>
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
  defp filter_options(values), do: Enum.map(values, &{display_label(&1), &1})

  defp display_label(value), do: value |> to_string() |> Phoenix.Naming.humanize()
end
