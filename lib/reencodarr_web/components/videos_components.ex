defmodule ReencodarrWeb.VideosComponents do
  @moduledoc "Video list rendering and display formatting."
  use ReencodarrWeb, :html
  @queueable_states [:needs_analysis, :analyzed, :crf_searched]

  defp active_video?(video), do: video.state in [:analyzing, :crf_searching, :encoding]

  defp queueable_video?(video), do: video.state in @queueable_states

  defp fail_action_video?(video),
    do: video.state in [:analyzed, :crf_searched, :crf_searching, :encoding]

  defp filters_active?(assigns) do
    assigns.search != "" or not is_nil(assigns.state_filter) or
      not is_nil(assigns.service_filter) or not is_nil(assigns.hdr_filter)
  end

  def page(assigns) do
    assigns =
      assign(assigns,
        filters_active: filters_active?(assigns),
        select_count: MapSet.size(assigns.selected),
        url_query: assigns.url_query
      )

    ~H"""
    <div class="workbench page-stack">
      <div class="page-stack">
        <.videos_header total={@total} select_count={@select_count} filters_active={@filters_active} />
        <.video_state_filters
          valid_states={@valid_states}
          state_counts={@state_counts}
          state_filter={@state_filter}
        />
        <.videos_toolbar
          search={@search}
          state_filter={@state_filter}
          service_filter={@service_filter}
          hdr_filter={@hdr_filter}
          valid_states={@valid_states}
          per_page={@per_page}
          per_page_options={@per_page_options}
        />
        <div class="queue-presets" aria-label="Queue views">
          <.link patch={queue_path(@url_query, "needs_analysis")}>Analysis queue</.link>
          <.link patch={queue_path(@url_query, "analyzed")}>CRF search queue</.link>
          <.link patch={queue_path(@url_query, "crf_searched")}>Encode queue</.link>
          <.link navigate="/failures">Review failures</.link>
        </div>
        <.videos_results
          loading={@loading}
          videos={@videos}
          selected={@selected}
          select_count={@select_count}
          sort_by={@sort_by}
          sort_dir={@sort_dir}
          expanded_bad_forms={@expanded_bad_forms}
          meta={@meta}
          url_query={@url_query}
        />
      </div>
      <.modal
        :if={@inspection_id}
        id="video-inspection"
        show
        on_cancel={JS.patch(@close_inspection)}
        title="Video details"
      >
        <h2>Video details</h2>
        <p :if={@inspection_loading} role="status">Loading video…</p>
        <p :if={not @inspection_loading and is_nil(@inspection)}>Video not found.</p>
        <.video_inspection :if={@inspection} inspection={@inspection} />
      </.modal>
    </div>
    """
  end

  defp queue_path(query, state),
    do:
      ~p"/videos?#{Map.merge(query, %{"state" => state, "sort_by" => "priority", "sort_dir" => "desc"})}"

  attr :inspection, :map, required: true

  defp video_inspection(assigns) do
    assigns = assign(assigns, video: assigns.inspection.video, vmafs: assigns.inspection.vmafs)

    ~H"""
    <div class="video-inspection page-stack">
      <p class="full-path">{@video.path}</p>
      <dl class="inspection-facts">
        <div>
          <dt>State</dt><dd>{state_label(@video.state)}</dd>
        </div>
        <div>
          <dt>Source</dt><dd>{service_display(@video.service_type)}</dd>
        </div>
        <div>
          <dt>Resolution</dt><dd>{format_resolution(@video.width, @video.height)}</dd>
        </div>
        <div>
          <dt>Size</dt><dd>{format_size(@video.size)}</dd>
        </div>
        <div>
          <dt>Video</dt><dd>{Enum.join(@video.video_codecs || [], ", ")}</dd>
        </div>
        <div>
          <dt>Audio</dt><dd>{Enum.join(@video.audio_codecs || [], ", ")}</dd>
        </div>
        <div>
          <dt>Bitrate</dt><dd>{format_bitrate(@video.bitrate)}</dd>
        </div>
        <div>
          <dt>Priority</dt><dd>{@video.priority}</dd>
        </div>
        <div>
          <dt>Worker</dt><dd>{@video.encode_worker_id || @video.crf_search_worker_id || "—"}</dd>
        </div>
        <div>
          <dt>Worker control</dt><dd>{@video.worker_control_desired_state || "—"}</dd>
        </div>
      </dl>
      <.video_actions video={@video} id_prefix="inspection" allow_mark_bad={false} />
      <section>
        <h3>CRF results</h3>
        <p :if={@vmafs == []} class="text-[var(--wb-muted)]">No CRF results.</p>
        <div :for={vmaf <- @vmafs} class="crf-result-row">
          <span>CRF {vmaf.crf}</span><span>VMAF {vmaf.score}</span>
          <span>{if vmaf.id == @video.chosen_vmaf_id, do: "Chosen", else: ""}</span>
        </div>
      </section>
      <.link
        :if={@video.state == :failed}
        navigate={~p"/failures?#{%{search: @video.path}}"}
        class="section-action"
      >View failure details</.link>
      <.link navigate={~p"/bad-files?#{%{search: @video.path}}"} class="section-action">View bad-file issues</.link>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Components
  # ---------------------------------------------------------------------------

  attr :total, :integer, required: true
  attr :select_count, :integer, required: true
  attr :filters_active, :boolean, required: true

  defp videos_header(assigns) do
    ~H"""
    <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
      <div>
        <h1 class="text-2xl font-bold text-[var(--wb-text)] sm:text-3xl">Videos</h1>
        <p class="text-[var(--wb-muted)]">{@total} total</p>
      </div>
      <div class="flex flex-col gap-2 sm:flex-row sm:flex-wrap">
        <%= if @select_count > 0 do %>
          <button
            phx-click="prioritize_selected"
            class="w-full px-4 py-2 text-sm font-medium text-[var(--wb-text)] bg-[#304e40] rounded-md transition-colors hover:bg-[var(--wb-raised)] sm:w-auto"
          >
            Prioritize {@select_count} selected
          </button>
          <button
            phx-click="reset_selected"
            class="w-full px-4 py-2 text-sm font-medium text-[var(--wb-text)] bg-[#46395e] rounded-md transition-colors hover:bg-[var(--wb-raised)] sm:w-auto"
          >
            Reset {@select_count} selected
          </button>
          <button
            phx-click="deselect_all"
            class="w-full px-4 py-2 text-sm font-medium text-[var(--wb-muted)] bg-[var(--wb-raised)] rounded-md transition-colors hover:bg-[var(--wb-raised)] sm:w-auto"
          >
            Clear selection
          </button>
        <% end %>
        <%= if @filters_active do %>
          <button
            phx-click="clear_filters"
            class="w-full px-4 py-2 text-sm font-medium text-[var(--wb-muted)] bg-[var(--wb-raised)] rounded-md transition-colors hover:bg-[var(--wb-raised)] sm:w-auto"
          >
            Clear filters
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  attr :valid_states, :list, required: true
  attr :state_counts, :map, required: true
  attr :state_filter, :any, required: true

  defp video_state_filters(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-2">
      <%= for state <- @valid_states do %>
        <% count = Map.get(@state_counts, String.to_existing_atom(state), 0) %>
        <button
          phx-click="quick_filter_state"
          phx-value-state={state}
          class={"flex items-center gap-1.5 px-3 py-1.5 rounded-md text-xs font-medium transition-all #{stats_badge_class(state, @state_filter)}"}
        >
          <span>{state_label(state)}</span>
          <span data-role="state-count" class="bg-black/20 rounded-md px-1.5 py-0.5 tabular-nums">{count}</span>
        </button>
      <% end %>
    </div>
    """
  end

  attr :search, :string, required: true
  attr :state_filter, :any, required: true
  attr :service_filter, :any, required: true
  attr :hdr_filter, :any, required: true
  attr :valid_states, :list, required: true
  attr :per_page, :integer, required: true
  attr :per_page_options, :list, required: true

  defp videos_toolbar(assigns) do
    ~H"""
    <div class="bg-[var(--wb-panel)] rounded-md border border-[var(--wb-line)] p-3 sm:p-4">
      <div class="flex flex-col gap-3 lg:flex-row lg:items-center">
        <form id="videos-filters" phx-change="set_filters" phx-no-unused-field class="contents">
          <div class="min-w-0 flex-1">
            <input
              type="text"
              name="search"
              value={@search}
              placeholder="Search by path..."
              phx-debounce="700"
              aria-label="Search videos by path"
              class="w-full bg-[var(--wb-raised)] border border-[var(--wb-line)] text-[var(--wb-text)] rounded-md px-3 py-2 text-sm focus:outline-[var(--wb-blue)] focus:outline-[var(--wb-blue)] placeholder:text-[var(--wb-muted)]"
            />
          </div>
          <select
            name="state"
            aria-label="Filter videos by state"
            class="w-full bg-[var(--wb-raised)] border border-[var(--wb-line)] text-[var(--wb-text)] rounded-md px-3 py-2 text-sm focus:outline-[var(--wb-blue)] focus:outline-[var(--wb-blue)] lg:w-auto"
          >
            <option value="">All states</option>
            <%= for state <- @valid_states do %>
              <option value={state} selected={@state_filter == state}>{state_label(state)}</option>
            <% end %>
          </select>
          <select
            name="service"
            aria-label="Filter videos by source"
            class="w-full bg-[var(--wb-raised)] border border-[var(--wb-line)] text-[var(--wb-text)] rounded-md px-3 py-2 text-sm focus:outline-[var(--wb-blue)] focus:outline-[var(--wb-blue)] lg:w-auto"
          >
            <option value="">All sources</option>
            <option value="sonarr" selected={@service_filter == "sonarr"}>Sonarr (TV)</option>
            <option value="sportarr" selected={@service_filter == "sportarr"}>Sportarr</option>
            <option value="radarr" selected={@service_filter == "radarr"}>Radarr (Movies)</option>
          </select>
          <select
            name="hdr"
            aria-label="Filter videos by HDR"
            class="w-full bg-[var(--wb-raised)] border border-[var(--wb-line)] text-[var(--wb-text)] rounded-md px-3 py-2 text-sm focus:outline-[var(--wb-blue)] focus:outline-[var(--wb-blue)] lg:w-auto"
          >
            <option value="">Any HDR</option>
            <option value="true" selected={@hdr_filter == true}>HDR only</option>
            <option value="false" selected={@hdr_filter == false}>SDR only</option>
          </select>
        </form>

        <form id="videos-per-page" phx-change="set_per_page" phx-no-unused-field>
          <select
            name="per_page"
            aria-label="Videos per page"
            class="w-full bg-[var(--wb-raised)] border border-[var(--wb-line)] text-[var(--wb-text)] rounded-md px-3 py-2 text-sm focus:outline-[var(--wb-blue)] focus:outline-[var(--wb-blue)] sm:w-auto"
          >
            <%= for n <- @per_page_options do %>
              <option value={n} selected={@per_page == n}>{n} / page</option>
            <% end %>
          </select>
        </form>
      </div>
    </div>
    """
  end

  attr :loading, :boolean, required: true
  attr :videos, :list, required: true
  attr :selected, MapSet, required: true
  attr :select_count, :integer, required: true
  attr :sort_by, :atom, required: true
  attr :sort_dir, :atom, required: true
  attr :expanded_bad_forms, :list, required: true
  attr :meta, Flop.Meta, required: true
  attr :url_query, :map, required: true

  defp videos_results(assigns) do
    ~H"""
    <%= if @loading and @videos == [] do %>
      <div class="bg-[var(--wb-panel)] rounded-md border border-[var(--wb-line)] p-16 text-center">
        <p class="text-[var(--wb-muted)]" role="status">Loading videos…</p>
      </div>
    <% else %>
      <%= if @loading do %>
        <p class="px-1 text-sm text-[var(--wb-muted)]">Refreshing results...</p>
      <% end %>
      <.videos_table
        videos={@videos}
        selected={@selected}
        select_count={@select_count}
        sort_by={@sort_by}
        sort_dir={@sort_dir}
        expanded_bad_forms={@expanded_bad_forms}
      />

      <.flop_pagination
        id="videos-flop-pagination"
        meta={@meta}
        base_path="/videos"
        query={@url_query}
        mode={:simple}
      />
    <% end %>
    """
  end

  attr :videos, :list, required: true
  attr :selected, MapSet, required: true
  attr :select_count, :integer, required: true
  attr :sort_by, :atom, required: true
  attr :sort_dir, :atom, required: true
  attr :expanded_bad_forms, :list, required: true

  defp videos_table(assigns) do
    ~H"""
    <div class="bg-[var(--wb-panel)] rounded-md border border-[var(--wb-line)] overflow-x-auto">
      <table class="videos-table min-w-full divide-y divide-[var(--wb-line)] text-sm">
        <thead class="bg-[var(--wb-raised)]">
          <tr>
            <th class="w-10 px-3 py-3 text-center">
              <%= if length(@videos) > 0 do %>
                <input
                  type="checkbox"
                  checked={@select_count == length(@videos)}
                  phx-click={
                    if @select_count == length(@videos), do: "deselect_all", else: "select_all"
                  }
                  title={
                    if @select_count == length(@videos),
                      do: "Deselect all",
                      else: "Select all on page"
                  }
                  aria-label={
                    if @select_count == length(@videos),
                      do: "Deselect all videos on this page",
                      else: "Select all videos on this page"
                  }
                  class="rounded border-gray-500 bg-[var(--wb-raised)] text-purple-500 focus:outline-[var(--wb-blue)] focus:ring-offset-gray-800 cursor-pointer"
                />
                <span class="sm:hidden">Select page</span>
              <% end %>
            </th>
            <.col_header
              col={:path}
              label="File"
              sort_by={@sort_by}
              sort_dir={@sort_dir}
              class="w-full"
            />
            <.col_header col={:state} label="State" sort_by={@sort_by} sort_dir={@sort_dir} />
            <.col_header col={:size} label="Size" sort_by={@sort_by} sort_dir={@sort_dir} />
            <.col_header
              col={:updated_at}
              label="Updated"
              sort_by={@sort_by}
              sort_dir={@sort_dir}
            />
            <th class="px-4 py-3 text-left text-xs font-medium text-[var(--wb-muted)] normal-case tracking-normal whitespace-nowrap">
              Actions
            </th>
          </tr>
        </thead>
        <tbody
          id="videos-table-body"
          phx-hook="RangeSelectCheckboxes"
          class="divide-y divide-[var(--wb-line)]"
        >
          <%= for video <- @videos do %>
            <.video_row video={video} selected={@selected} expanded_bad_forms={@expanded_bad_forms} />
          <% end %>
          <%= if @videos == [] do %>
            <tr>
              <td colspan="6" class="px-8 py-12 text-center text-[var(--wb-muted)]">
                No videos match the current filters.
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr :video, :map, required: true
  attr :selected, MapSet, required: true
  attr :expanded_bad_forms, :list, required: true

  defp video_row(assigns) do
    ~H"""
    <tr class={"transition-colors #{if MapSet.member?(@selected, @video.id), do: "bg-purple-900/20", else: "hover:bg-[var(--wb-raised)]"}"}>
      <td class="w-10 px-3 py-2 text-center">
        <input
          type="checkbox"
          checked={MapSet.member?(@selected, @video.id)}
          data-range-select="video"
          data-id={@video.id}
          aria-label={"Select video #{Path.basename(@video.path)}"}
          class="rounded border-gray-500 bg-[var(--wb-raised)] text-purple-500 focus:outline-[var(--wb-blue)] focus:ring-offset-gray-800 cursor-pointer"
        />
      </td>
      <td class="px-4 py-2 text-[var(--wb-text)] max-w-0 w-full" title={@video.path}>
        <button phx-click="inspect_video" phx-value-id={@video.id} class="video-file-link">{Path.basename(
          @video.path
        )}</button>
        <%= if @video.title do %>
          <div class="text-xs text-[var(--wb-muted)] truncate">
            {@video.title}
            <%= if @video.content_year do %>
              ({@video.content_year})
            <% end %>
          </div>
        <% end %>
        <div class="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-[var(--wb-muted)]">
          <span class="truncate max-w-full">{Path.basename(Path.dirname(@video.path))}</span>
          <span>{format_resolution(@video.width, @video.height)}</span>
          <span>{format_bitrate(@video.bitrate)}</span>
          <span>{service_display(@video.service_type)}</span>
          <%= if @video.hdr do %>
            <.hdr_badge hdr={@video.hdr} />
          <% end %>
          <%= if @video.space_saved_bytes > 0 do %>
            <.space_saved_badge space_saved_bytes={@video.space_saved_bytes} />
          <% end %>
        </div>
      </td>
      <td class="px-4 py-2 whitespace-nowrap">
        <span class={"inline-flex items-center px-2 py-0.5 rounded text-xs font-medium #{state_badge_class(@video.state)}"}>
          {state_label(@video.state)}
        </span>
      </td>
      <td class="px-4 py-2 text-[var(--wb-text)] whitespace-nowrap">{format_size(@video.size)}</td>
      <td class="px-4 py-2 text-[var(--wb-muted)] whitespace-nowrap text-xs">
        {format_datetime(@video.updated_at)}
      </td>
      <td class="px-4 py-2">
        <.video_actions video={@video} />
        <.mark_bad_form :if={@video.id in @expanded_bad_forms} video={@video} />
      </td>
    </tr>
    """
  end

  attr :video, :map, required: true

  attr :id_prefix, :string, default: "video"
  attr :allow_mark_bad, :boolean, default: true

  defp video_actions(assigns) do
    ~H"""
    <details
      id={"#{@id_prefix}-actions-#{@video.id}"}
      class="row-actions"
      phx-mounted={JS.ignore_attributes("open")}
    >
      <summary class="workbench-button">Actions</summary>
      <div class="row-action-items">
        <%= if queueable_video?(@video) do %>
          <button
            phx-click="prioritize_video"
            phx-value-id={@video.id}
            title="Move this queued video to the top"
            class="text-emerald-400 hover:text-emerald-300 text-xs"
          >
            Prioritize
          </button>
        <% end %>
        <%= if queueable_video?(@video) and ReencodarrWeb.VideoPresentation.season_directory(@video.path) do %>
          <button
            phx-click="prioritize_season_visible"
            phx-value-id={@video.id}
            title="Move all videos from this season to the top"
            class="text-emerald-300 hover:text-emerald-200 text-xs"
          >
            Prioritize season
          </button>
        <% end %>
        <button
          :if={@video.state in [:crf_searching, :encoding]}
          phx-click="control_video"
          phx-value-id={@video.id}
          phx-value-action={
            if @video.worker_control_desired_state == :paused, do: "resume", else: "pause"
          }
          class="section-action"
        >{if @video.worker_control_desired_state == :paused, do: "Resume worker", else: "Pause worker"}</button>
        <%= if fail_action_video?(@video) do %>
          <button
            phx-click="fail_video"
            phx-value-id={@video.id}
            data-confirm={"#{if active_video?(@video), do: "Stop", else: "Remove from queue:"} #{Path.basename(@video.path)}?"}
            title="Stop job"
            aria-label="Stop job"
            class="text-red-500 hover:text-red-400 text-xs font-semibold"
          >
            {if active_video?(@video), do: "Stop worker job", else: "Remove from queue"}
          </button>
        <% end %>
        <button
          :if={not active_video?(@video)}
          phx-click="force_reanalyze"
          phx-value-id={@video.id}
          title="Force re-analyze (clears VMAFs and resets metadata)"
          class="text-[var(--wb-blue)] hover:text-blue-300 text-xs"
        >
          Analyze again
        </button>
        <%= if @video.state in [:failed, :encoded, :crf_searched, :analyzed] do %>
          <button
            phx-click="reset_video"
            phx-value-id={@video.id}
            title="Reset to needs_analysis"
            class="text-[var(--wb-lilac)] hover:text-purple-300 text-xs"
          >
            Reset
          </button>
        <% end %>
        <button
          :if={@allow_mark_bad}
          phx-click="toggle_mark_bad"
          phx-value-id={@video.id}
          title="Open bad-file form"
          class="text-[var(--wb-amber)] hover:text-amber-200 text-xs"
        >
          Mark bad
        </button>
        <button
          :if={not active_video?(@video)}
          phx-click="delete_video"
          phx-value-id={@video.id}
          data-confirm={"Delete #{Path.basename(@video.path)}?"}
          title="Remove from database"
          class="text-red-500 hover:text-red-400 text-xs"
        >
          Delete
        </button>
      </div>
    </details>
    """
  end

  attr :video, :map, required: true

  defp mark_bad_form(assigns) do
    ~H"""
    <form
      id={"mark-bad-form-#{@video.id}"}
      phx-submit="mark_bad"
      phx-value-id={@video.id}
      class="mt-2 rounded border border-amber-700/60 bg-amber-950/30 p-2"
    >
      <div class="flex flex-wrap items-center gap-2">
        <input
          type="text"
          name="issue[manual_reason]"
          placeholder="Why is this bad?"
          class="min-w-[13rem] flex-1 rounded border border-[var(--wb-line)] bg-[var(--wb-raised)] px-2 py-1.5 text-xs text-[var(--wb-text)] placeholder:text-[var(--wb-muted)]"
        />
        <input
          type="text"
          name="issue[manual_note]"
          placeholder="Optional note"
          class="min-w-[14rem] flex-1 rounded border border-[var(--wb-line)] bg-[var(--wb-raised)] px-2 py-1.5 text-xs text-[var(--wb-text)] placeholder:text-[var(--wb-muted)]"
        />
        <button
          type="submit"
          class="rounded bg-amber-600 px-3 py-1.5 text-xs font-medium text-[var(--wb-text)] hover:bg-[var(--wb-raised)]"
        >
          save
        </button>
        <button
          type="button"
          phx-click="toggle_mark_bad"
          phx-value-id={@video.id}
          class="text-xs text-[var(--wb-muted)] hover:text-[var(--wb-text)]"
        >
          cancel
        </button>
      </div>
    </form>
    """
  end

  attr :col, :atom, required: true
  attr :label, :string, required: true
  attr :sort_by, :atom, required: true
  attr :sort_dir, :atom, required: true
  attr :class, :string, default: ""

  defp col_header(assigns) do
    assigns =
      assign(assigns,
        is_sorted: assigns.sort_by == assigns.col,
        icon: sort_icon(assigns.sort_by, assigns.col, assigns.sort_dir)
      )

    ~H"""
    <th class={"px-4 py-3 text-left text-xs font-medium text-[var(--wb-muted)] normal-case tracking-normal whitespace-nowrap #{@class}"}>
      <button
        phx-click="sort"
        phx-value-col={@col}
        class={"flex items-center gap-1 hover:text-[var(--wb-text)] transition-colors #{if @is_sorted, do: "text-[var(--wb-lilac)]", else: ""}"}
      >
        {@label}
        <span class="opacity-60">{@icon}</span>
      </button>
    </th>
    """
  end

  # ---------------------------------------------------------------------------
  # Display helpers
  # ---------------------------------------------------------------------------

  defp sort_icon(sort_by, col, dir) when sort_by == col, do: if(dir == :asc, do: "↑", else: "↓")
  defp sort_icon(_, _, _), do: "↕"

  @state_badge_classes %{
    needs_analysis: "state-queued",
    analyzing: "state-analysis",
    analyzed: "state-search",
    crf_searching: "state-search",
    crf_searched: "state-encode",
    encoding: "state-encode",
    encoded: "state-complete",
    failed: "state-failed"
  }

  @state_labels %{
    needs_analysis: "Awaiting analysis",
    analyzing: "Analyzing",
    analyzed: "Awaiting CRF search",
    crf_searching: "CRF search",
    crf_searched: "Awaiting encode",
    encoding: "Encoding",
    encoded: "Encoded",
    failed: "Failed"
  }

  defp state_label(state) when is_binary(state), do: state_label(String.to_existing_atom(state))
  defp state_label(state), do: Map.fetch!(@state_labels, state)

  defp state_badge_class(state),
    do: "video-state " <> Map.get(@state_badge_classes, state, "state-queued")

  defp stats_badge_class(state, active_filter) do
    state_badge_class(String.to_existing_atom(state)) <>
      if(active_filter == state, do: " is-selected", else: "")
  end

  defp service_display(nil), do: "-"
  defp service_display(:sonarr), do: "TV"
  defp service_display(:radarr), do: "Movie"
  defp service_display(_), do: "-"

  attr :hdr, :any, required: true

  defp hdr_badge(%{hdr: v} = assigns) when v in [nil, ""],
    do: ~H|<span class="text-[var(--wb-muted)]">—</span>|

  defp hdr_badge(assigns) do
    ~H"""
    <span class="inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium bg-amber-900/60 text-[var(--wb-amber)] border border-amber-700/50">
      {@hdr}
    </span>
    """
  end

  attr :space_saved_bytes, :integer, required: true

  defp space_saved_badge(assigns) do
    assigns =
      assign(assigns,
        display: format_size(assigns.space_saved_bytes),
        saved: assigns.space_saved_bytes
      )

    ~H"""
    <span class={"tabular-nums #{space_saved_color(@saved)}"} title="Space saved">
      {@display}
    </span>
    """
  end

  defp space_saved_color(bytes) when bytes >= 1_073_741_824, do: "text-green-300"
  defp space_saved_color(bytes) when bytes >= 536_870_912, do: "text-yellow-300"
  defp space_saved_color(_), do: "text-red-400"

  defp format_size(nil), do: "-"
  defp format_size(0), do: "-"

  defp format_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GiB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MiB"
      true -> "#{bytes} B"
    end
  end

  defp format_bitrate(nil), do: "-"
  defp format_bitrate(0), do: "-"

  defp format_bitrate(bps) when is_integer(bps) do
    "#{Float.round(bps / 1_000_000, 1)} Mb/s"
  end

  defp format_resolution(nil, _), do: "-"
  defp format_resolution(_, nil), do: "-"

  defp format_resolution(w, h) do
    label =
      cond do
        h >= 2160 -> "4K"
        h >= 1080 -> "1080p"
        h >= 720 -> "720p"
        true -> nil
      end

    if label, do: "#{w}x#{h} (#{label})", else: "#{w}x#{h}"
  end

  defp format_datetime(nil), do: "-"
  defp format_datetime(%NaiveDateTime{} = dt), do: NaiveDateTime.to_date(dt) |> Date.to_iso8601()
  defp format_datetime(%DateTime{} = dt), do: format_datetime(DateTime.to_naive(dt))
end
