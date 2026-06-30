defmodule ReencodarrWeb.FailuresLive do
  @moduledoc """
  Live dashboard for failures analysis and management.

  ## Failures Analysis Features:
  - Failed video discovery and filtering
  - Detailed failure analysis with codec, size, path information
  - Failure retry and bulk management
  - Sorting and searching capabilities

  ## Architecture Notes:
  - Modern Dashboard V2 UI with card-based layout
  - Memory optimized with efficient queries
  - Real-time updates via Events PubSub for failure state changes
  """

  use ReencodarrWeb, :live_view

  alias Reencodarr.Core.Parsers
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Media
  alias ReencodarrWeb.Live.FlopList

  @update_interval 30_000
  @default_per_page 20
  @stage_filter_values ["all", "analysis", "crf_search", "encoding", "post_process"]
  @category_filter_values ["all", "file_access", "process_failure", "timeout", "codec_issues"]
  @param_keys [:failure_filter, :category_filter, :search_term, :page, :per_page]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> setup_failures_data()
      |> assign(:meta, %Flop.Meta{})
      |> assign_url_query()
      |> assign(:loaded_once, false)
      |> assign_placeholder_data()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())
      schedule_periodic_update()
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
      |> maybe_clear_selection(filters_changed?)
      |> assign_url_query()
      |> reload_failures_for_params(filters_changed?)

    {:noreply, socket}
  end

  @impl true
  def handle_info(:update_failures_data, socket) do
    schedule_periodic_update()
    {:noreply, async_load_failures(socket)}
  end

  # Handle events that might affect failures (video state changes, encoding completion, etc.)
  @impl true
  def handle_info({event, _data}, socket)
      when event in [
             :encoding_completed,
             :crf_search_completed,
             :analyzer_completed,
             :video_failed
           ] do
    # Reload failures when pipeline events occur that might change failure state
    {:noreply, async_load_failures(socket)}
  end

  # Catch-all for other Events we don't need to handle
  @impl true
  def handle_info({_event, _data}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("retry_failed_video", %{"video_id" => video_id}, socket) do
    case Parsers.parse_integer_exact(video_id) do
      {:ok, id} ->
        case Media.get_video(id) do
          nil ->
            {:noreply, put_flash(socket, :error, "Video not found")}

          video ->
            # Reset the video to needs_analysis state and clear bitrate to trigger reanalysis
            Media.update_video(video, %{bitrate: nil})
            Media.mark_as_needs_analysis(video)
            Media.resolve_video_failures(video.id)

            # Reload the failures data
            {:noreply,
             socket
             |> put_flash(:info, "Video #{video.id} marked for retry")
             |> async_load_failures()}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Invalid video ID")}
    end
  end

  @impl true
  def handle_event("reset_all_failures", _params, socket) do
    Media.reset_all_failures()

    {:noreply,
     socket
     |> push_patch(to: patch_path(socket.assigns, page: 1))
     |> put_flash(:info, "All failures have been reset")}
  end

  @impl true
  def handle_event("retry_failure_code", %{"code" => failure_code}, socket) do
    result = Media.retry_failed_videos_by_failure_code(failure_code)

    {:noreply,
     socket
     |> put_flash(
       :info,
       "Queued retry for #{result.videos_retried} failed videos with #{failure_code}"
     )
     |> async_load_failures()}
  end

  @impl true
  def handle_event("toggle_details", %{"video_id" => video_id}, socket) do
    video_id = Parsers.parse_int(video_id)
    expanded = socket.assigns.expanded_details

    new_expanded =
      if video_id in expanded do
        List.delete(expanded, video_id)
      else
        [video_id | expanded]
      end

    {:noreply, assign(socket, :expanded_details, new_expanded)}
  end

  @impl true
  def handle_event("toggle_select", %{"video_id" => video_id}, socket) do
    video_id = Parsers.parse_int(video_id)
    selected = socket.assigns.selected_videos

    new_selected =
      if MapSet.member?(selected, video_id) do
        MapSet.delete(selected, video_id)
      else
        MapSet.put(selected, video_id)
      end

    {:noreply, assign(socket, :selected_videos, new_selected)}
  end

  @impl true
  def handle_event("select_all", _params, socket) do
    video_ids = Enum.map(socket.assigns.failed_videos, & &1.id) |> MapSet.new()
    {:noreply, assign(socket, :selected_videos, video_ids)}
  end

  @impl true
  def handle_event("deselect_all", _params, socket) do
    {:noreply, assign(socket, :selected_videos, MapSet.new())}
  end

  @impl true
  def handle_event("retry_selected", _params, socket) do
    selected_ids = socket.assigns.selected_videos |> MapSet.to_list()

    if selected_ids == [] do
      {:noreply, put_flash(socket, :error, "No videos selected")}
    else
      # Reset each selected video
      Enum.each(selected_ids, &retry_video/1)

      # Clear selection and reload
      socket =
        socket
        |> assign(:selected_videos, MapSet.new())
        |> async_load_failures()

      count = Enum.count(selected_ids)
      {:noreply, put_flash(socket, :info, "Retrying #{count} selected videos")}
    end
  end

  @impl true
  def handle_event("filter_failures", %{"filter" => filter}, socket) do
    normalized_filter = if filter in @stage_filter_values, do: filter, else: "all"

    {:noreply,
     push_patch(socket, to: patch_path(socket.assigns, stage: normalized_filter, page: 1))}
  end

  @impl true
  def handle_event("filter_category", %{"category" => category}, socket) do
    normalized_category = if category in @category_filter_values, do: category, else: "all"

    {:noreply,
     push_patch(socket, to: patch_path(socket.assigns, category: normalized_category, page: 1))}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: "/failures")}
  end

  @impl true
  def handle_event("search", %{"search" => search_term}, socket) do
    {:noreply,
     push_patch(socket,
       to: patch_path(socket.assigns, search: normalize_search_term(search_term), page: 1)
     )}
  end

  @impl true
  def handle_async(:load_failures, {:ok, payload}, socket) do
    {:noreply, assign_failure_payload(socket, payload)}
  end

  @impl true
  def handle_async(:load_failures, {:exit, _reason}, socket) do
    {:noreply, socket |> assign(:loading, false) |> put_flash(:error, "Failed to load failures")}
  end

  # Private helper functions

  defp retry_video(video_id) do
    case Media.get_video(video_id) do
      nil ->
        :ok

      video ->
        Media.update_video(video, %{bitrate: nil})
        Media.mark_as_needs_analysis(video)
        Media.resolve_video_failures(video.id)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-[calc(100dvh-3.5rem)] bg-gray-900 px-3 py-4 sm:px-4 sm:py-6 lg:px-6">
      <div class="mx-auto max-w-7xl space-y-4 sm:space-y-6">
        <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <h1 class="text-2xl font-bold text-white sm:text-3xl">
              Failures ({@total_count})
            </h1>
            <p class="text-gray-400">Monitor and manage failed video processing operations</p>
          </div>
          <div class="flex flex-col gap-2 sm:flex-row">
            <%= if MapSet.size(@selected_videos) > 0 do %>
              <button
                phx-click="retry_selected"
                class="w-full px-4 py-2 text-sm font-medium text-white bg-blue-600 rounded-lg transition-colors hover:bg-blue-700 sm:w-auto"
              >
                Retry Selected ({MapSet.size(@selected_videos)})
              </button>
            <% end %>
            <button
              phx-click="reset_all_failures"
              class="w-full px-4 py-2 text-sm font-medium text-white bg-red-600 rounded-lg transition-colors hover:bg-red-700 sm:w-auto"
            >
              Reset All
            </button>
          </div>
        </div>

        <%= if @loading do %>
          <div class="bg-gray-800 rounded-lg shadow-lg p-12 border border-gray-700 text-center">
            <div class="animate-spin rounded-full h-12 w-12 border-b-2 border-purple-500 mx-auto mb-4">
            </div>
            <p class="text-gray-400">Loading failure data...</p>
          </div>
        <% else %>
          <.failure_filter_bar
            search_term={@search_term}
            failure_filter={@failure_filter}
            category_filter={@category_filter}
          />

          <.retry_failure_code_panel actions={@failure_code_actions} />
          <.failure_table
            failed_videos={@failed_videos}
            video_failures={@video_failures}
            selected_videos={@selected_videos}
            expanded_details={@expanded_details}
            search_term={@search_term}
            meta={@meta}
            url_query={@url_query}
          />
          <.common_failure_patterns patterns={@failure_patterns} />
        <% end %>
      </div>
    </div>
    """
  end

  # Private Helper Functions

  attr :search_term, :string, required: true
  attr :failure_filter, :string, required: true
  attr :category_filter, :string, required: true

  defp failure_filter_bar(assigns) do
    assigns =
      assign(assigns,
        stage_options: [
          {"all", "All", "bg-purple-600 text-white"},
          {"analysis", "Analysis", "bg-purple-600 text-white"},
          {"crf_search", "CRF", "bg-blue-600 text-white"},
          {"encoding", "Encoding", "bg-amber-600 text-white"},
          {"post_process", "Post", "bg-red-600 text-white"}
        ],
        category_options: [
          {"all", "All"},
          {"process_failure", "Process"},
          {"timeout", "Timeout"},
          {"codec_issues", "Codec"},
          {"file_access", "File"}
        ]
      )

    ~H"""
    <div class="bg-gray-800 rounded-lg shadow-lg p-4 border border-gray-700">
      <div class="flex flex-col gap-3">
        <form id="failures-search" phx-change="search">
          <input
            type="text"
            name="search"
            value={@search_term}
            placeholder="Search by file path..."
            phx-debounce="300"
            aria-label="Search failed videos by file path"
            class="w-full px-4 py-2 bg-gray-700 border border-gray-600 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500 text-white placeholder-gray-400"
          />
        </form>

        <div class="flex flex-col gap-3 sm:flex-row">
          <div class="flex flex-col gap-2 sm:flex-row sm:items-center">
            <span class="text-sm font-medium text-gray-300 whitespace-nowrap">Stage:</span>
            <div class="inline-flex flex-wrap gap-1" role="group" aria-label="Filter by stage">
              <%= for {value, label, active_class} <- @stage_options do %>
                <button
                  phx-click="filter_failures"
                  phx-value-filter={value}
                  aria-pressed={@failure_filter == value}
                  class={failure_filter_button_class(@failure_filter == value, active_class)}
                >
                  {label}
                </button>
              <% end %>
            </div>
          </div>

          <div class="flex flex-col gap-2 sm:flex-row sm:items-center">
            <span class="text-sm font-medium text-gray-300 whitespace-nowrap">Type:</span>
            <div class="inline-flex flex-wrap gap-1" role="group" aria-label="Filter by category">
              <%= for {value, label} <- @category_options do %>
                <button
                  phx-click="filter_category"
                  phx-value-category={value}
                  aria-pressed={@category_filter == value}
                  class={
                    failure_filter_button_class(@category_filter == value, "bg-green-600 text-white")
                  }
                >
                  {label}
                </button>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp failure_filter_button_class(true, active_class),
    do: "px-2 py-1 text-xs rounded transition-colors #{active_class}"

  defp failure_filter_button_class(false, _active_class),
    do: "px-2 py-1 text-xs rounded transition-colors bg-gray-700 text-gray-300 hover:bg-gray-600"

  attr :actions, :list, required: true

  defp retry_failure_code_panel(assigns) do
    ~H"""
    <%= if @actions != [] do %>
      <div class="bg-gray-800 rounded-lg shadow-lg p-4 border border-gray-700">
        <div class="flex flex-col gap-3">
          <div>
            <h2 class="text-sm font-semibold text-white">Retry By Error Code</h2>
            <p class="text-xs text-gray-400">
              Retry all failed videos whose unresolved failures include the selected code by sending them back to analysis.
            </p>
          </div>
          <div class="flex flex-wrap gap-2">
            <%= for action <- @actions do %>
              <button
                phx-click="retry_failure_code"
                phx-value-code={action.code}
                class="inline-flex items-center gap-2 rounded-lg border border-gray-600 bg-gray-750 px-3 py-2 text-xs font-medium text-gray-200 transition-colors hover:bg-gray-700"
              >
                <span>{action.code}</span>
                <span class="rounded bg-gray-900 px-1.5 py-0.5 text-[11px] text-gray-300">
                  {action.count}
                </span>
              </button>
            <% end %>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  attr :failed_videos, :list, required: true
  attr :video_failures, :map, required: true
  attr :selected_videos, MapSet, required: true
  attr :expanded_details, :list, required: true
  attr :search_term, :string, required: true
  attr :meta, Flop.Meta, required: true
  attr :url_query, :map, required: true

  defp failure_table(assigns) do
    ~H"""
    <div class="bg-gray-800 rounded-lg shadow-lg overflow-hidden border border-gray-700">
      <%= if @failed_videos == [] do %>
        <div class="p-12 text-center">
          <div class="text-6xl mb-4">✅</div>
          <h3 class="text-xl font-semibold text-white mb-2">No Failures Found</h3>
          <p class="text-gray-400">
            <%= if @search_term != "" do %>
              No failed videos match your search criteria
            <% else %>
              All videos are processing successfully
            <% end %>
          </p>
        </div>
      <% else %>
        <div class="divide-y divide-gray-700">
          <div class="grid grid-cols-[auto_minmax(0,1fr)_auto_auto_auto_auto] gap-3 px-3 py-3 bg-gray-750 text-xs font-semibold text-gray-400 uppercase tracking-wider sm:gap-4 sm:px-4">
            <div class="flex items-center">
              <%= if MapSet.size(@selected_videos) == length(@failed_videos) and length(@failed_videos) > 0 do %>
                <input
                  type="checkbox"
                  checked
                  phx-click="deselect_all"
                  aria-label="Deselect all failed videos on this page"
                  class="w-4 h-4 text-blue-600 bg-gray-700 border-gray-600 rounded focus:ring-blue-500 cursor-pointer"
                />
              <% else %>
                <input
                  type="checkbox"
                  phx-click="select_all"
                  aria-label="Select all failed videos on this page"
                  class="w-4 h-4 text-blue-600 bg-gray-700 border-gray-600 rounded focus:ring-blue-500 cursor-pointer"
                />
              <% end %>
            </div>
            <div>Video</div>
            <div>Size</div>
            <div>Error</div>
            <div>When</div>
            <div></div>
          </div>

          <%= for video <- @failed_videos do %>
            <% latest_failure = latest_failure(@video_failures, video.id) %>

            <div class="hover:bg-gray-750">
              <div
                phx-click="toggle_details"
                phx-value-video_id={video.id}
                class="grid grid-cols-[auto_minmax(0,1fr)_auto_auto_auto_auto] gap-3 px-3 py-3 cursor-pointer sm:gap-4 sm:px-4"
              >
                <div
                  class="flex items-center"
                  phx-click="toggle_select"
                  phx-value-video_id={video.id}
                >
                  <input
                    type="checkbox"
                    checked={MapSet.member?(@selected_videos, video.id)}
                    aria-label={"Select failed video #{Path.basename(video.path)}"}
                    class="w-4 h-4 text-blue-600 bg-gray-700 border-gray-600 rounded focus:ring-blue-500 cursor-pointer pointer-events-none"
                  />
                </div>

                <div class="min-w-0">
                  <div class="text-sm font-medium text-white truncate" title={video.path}>
                    {Path.basename(video.path)}
                  </div>
                  <div class="flex items-center gap-2 mt-1 text-xs text-gray-400">
                    <%= if video.service_type do %>
                      <span>{video.service_type}</span>
                      <span>·</span>
                    <% end %>
                    <%= if video.width && video.height do %>
                      <span>{Reencodarr.Formatters.resolution(video.width, video.height)}</span>
                      <span>·</span>
                    <% end %>
                    <%= if video.video_codecs && length(video.video_codecs) > 0 do %>
                      <span>{format_codecs(video.video_codecs)}</span>
                    <% end %>
                    <%= if video.hdr do %>
                      <span>·</span>
                      <span class="text-purple-400">DV</span>
                    <% end %>
                  </div>
                </div>

                <div class="flex items-center text-sm text-gray-300">
                  <%= if video.size do %>
                    {Reencodarr.Formatters.file_size(video.size)}
                  <% else %>
                    <span class="text-gray-500">—</span>
                  <% end %>
                </div>

                <div class="flex items-center min-w-0">
                  <.failure_summary failure={latest_failure} />
                </div>

                <div class="flex items-center text-xs text-gray-400">
                  <%= if latest_failure do %>
                    {compact_relative_time(latest_failure.inserted_at)}
                  <% else %>
                    —
                  <% end %>
                </div>

                <div
                  class="flex items-center"
                  phx-click="retry_failed_video"
                  phx-value-video_id={video.id}
                >
                  <button class="px-3 py-1 text-xs font-medium text-white bg-blue-600 rounded hover:bg-blue-700 transition-colors pointer-events-none">
                    Retry
                  </button>
                </div>
              </div>

              <%= if video.id in @expanded_details do %>
                <.failure_details failures={Map.get(@video_failures, video.id)} />
              <% end %>
            </div>
          <% end %>
        </div>

        <.flop_pagination
          id="failures-flop-pagination"
          meta={@meta}
          base_path="/failures"
          query={@url_query}
          mode={:full}
          page_links={5}
          class="p-4 border-t border-gray-700"
        />
      <% end %>
    </div>
    """
  end

  attr :failure, :any, required: true

  defp failure_summary(assigns) do
    ~H"""
    <%= if @failure do %>
      <div class="flex items-start gap-2">
        <div class={"w-2 h-2 rounded-full mt-1.5 flex-shrink-0 #{stage_color(@failure.failure_stage)}"}>
        </div>
        <div class="min-w-0">
          <div class="text-xs font-semibold text-white">{@failure.failure_stage}</div>
          <div class="text-xs text-gray-400 truncate" title={@failure.failure_code}>
            <%= if @failure.failure_code do %>
              {@failure.failure_code}
            <% else %>
              {@failure.failure_category}
            <% end %>
          </div>
          <div class="text-xs text-gray-500 truncate" title={@failure.failure_message}>
            {truncate_failure_message(@failure.failure_message)}
          </div>
        </div>
      </div>
    <% else %>
      <span class="text-xs text-gray-500">No failure info</span>
    <% end %>
    """
  end

  attr :failures, :any, required: true

  defp failure_details(assigns) do
    ~H"""
    <div class="px-4 py-4 bg-gray-800/50 border-t border-gray-700">
      <%= case @failures do %>
        <% failures when is_list(failures) and failures != [] -> %>
          <% latest = List.first(failures) %>

          <%= if Map.get(latest.system_context || %{}, "command") do %>
            <div class="mb-3">
              <div class="text-xs font-semibold text-gray-300 mb-1">Command</div>
              <div class="bg-gray-900 p-3 rounded font-mono text-xs text-green-400 overflow-x-auto">
                $ {Map.get(latest.system_context, "command")}
              </div>
            </div>
          <% end %>

          <%= if has_command_details?(latest.system_context) do %>
            <div class="mb-3">
              <div class="text-xs font-semibold text-gray-300 mb-1">Output</div>
              <div class="bg-gray-900 p-3 rounded font-mono text-xs text-orange-300 overflow-x-auto max-h-60 overflow-y-auto">
                <pre class="whitespace-pre-wrap">{format_command_output(
                  Map.get(latest.system_context, "full_output")
                )}</pre>
              </div>
            </div>
          <% end %>

          <%= if length(failures) > 1 do %>
            <div>
              <div class="text-xs font-semibold text-gray-300 mb-2">
                History ({length(failures)} failures)
              </div>
              <div class="flex flex-wrap gap-2 text-xs">
                <%= for failure <- failures do %>
                  <span
                    class="px-2 py-1 bg-gray-700 text-gray-300 rounded"
                    title={failure.failure_message}
                  >
                    {failure.failure_stage}/{failure.failure_code || failure.failure_category} ({compact_relative_time(
                      failure.inserted_at
                    )})
                  </span>
                <% end %>
              </div>
            </div>
          <% end %>
        <% _ -> %>
          <div class="text-xs text-gray-400">No detailed failure information available</div>
      <% end %>
    </div>
    """
  end

  attr :patterns, :list, required: true

  defp common_failure_patterns(assigns) do
    ~H"""
    <%= if @patterns != [] do %>
      <div class="bg-gray-800 rounded-lg shadow-lg p-6 border border-gray-700">
        <h2 class="text-xl font-semibold text-white mb-4">Common Patterns</h2>
        <div class="space-y-2">
          <%= for pattern <- @patterns do %>
            <div class="flex items-center justify-between px-4 py-2 bg-gray-750 rounded">
              <div class="flex items-center gap-3">
                <div class={"w-2 h-2 rounded-full flex-shrink-0 #{stage_color(pattern.stage)}"}></div>
                <div>
                  <span class="text-sm font-medium text-white">
                    {pattern.stage}/{pattern.category}
                  </span>
                  <%= if pattern.code do %>
                    <span class="text-sm text-gray-400 ml-1">{pattern.code}</span>
                  <% end %>
                </div>
              </div>
              <div class="text-right">
                <div class="text-lg font-bold text-yellow-400">{pattern.count}</div>
                <div class="text-xs text-gray-500">occurrences</div>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  defp setup_failures_data(socket) do
    socket
    |> assign(:failure_filter, "all")
    |> assign(:category_filter, "all")
    |> assign(:expanded_details, [])
    |> assign(:selected_videos, MapSet.new())
    |> assign(:page, 1)
    |> assign(:per_page, 20)
    |> assign(:search_term, "")
  end

  defp assign_placeholder_data(socket) do
    socket
    |> assign(:loading, true)
    |> assign(:failed_videos, [])
    |> assign(:video_failures, %{})
    |> assign(:failure_stats, %{recent_count: 0})
    |> assign(:failure_patterns, [])
    |> assign(:failure_code_actions, [])
    |> assign(:total_count, 0)
    |> assign(:total_pages, 0)
  end

  defp async_load_failures(socket) do
    load_assigns = flop_list_assigns(socket.assigns)

    show_loading? = socket.assigns.failed_videos == []

    socket
    |> assign(:loading, show_loading?)
    |> start_async(:load_failures, fn ->
      fetch_failure_payload(load_assigns, include_support: false)
    end)
  end

  defp reload_failures_for_params(%{assigns: %{loaded_once: false}} = socket, _changed?),
    do:
      socket
      |> assign_failure_payload(fetch_failure_payload(flop_list_assigns(socket.assigns)))
      |> assign(:loaded_once, true)

  defp reload_failures_for_params(socket, false), do: socket

  defp reload_failures_for_params(socket, _changed?) do
    socket
    |> assign_failure_payload(
      fetch_failure_payload(flop_list_assigns(socket.assigns), include_support: false)
    )
  end

  defp fetch_failure_payload(assigns, opts \\ []) do
    payload = Media.load_failures_page(flop_params(assigns), opts)

    payload
    |> Map.put(:request, assigns)
    |> Map.put(:url_query, failures_url_query(%{assigns | page: payload.page}))
  end

  defp assign_failure_payload(socket, %{request: request} = payload) do
    if flop_list_assigns(socket.assigns) == request do
      payload = Map.delete(payload, :request)
      assign(socket, payload)
    else
      assign(socket, :loading, false)
    end
  end

  defp assign_failure_payload(socket, payload) do
    assign(socket, payload)
  end

  defp maybe_clear_selection(socket, true), do: assign(socket, :selected_videos, MapSet.new())
  defp maybe_clear_selection(socket, false), do: socket

  defp filters_changed?(assigns, filters) do
    Enum.any?(@param_keys, fn key -> Map.get(assigns, key) != Map.get(filters, key) end)
  end

  defp latest_failure(video_failures, video_id) do
    case Map.get(video_failures, video_id) do
      [failure | _rest] -> failure
      _ -> nil
    end
  end

  defp truncate_failure_message(message) do
    message = message || ""
    suffix = if String.length(message) > 40, do: "...", else: ""
    String.slice(message, 0, 40) <> suffix
  end

  defp flop_list_assigns(assigns) do
    %{
      page: assigns.page,
      per_page: assigns.per_page,
      failure_filter: assigns.failure_filter,
      category_filter: assigns.category_filter,
      search_term: assigns.search_term
    }
  end

  defp flop_params(assigns) do
    %{
      "page" => to_string(assigns.page),
      "page_size" => to_string(assigns.per_page),
      "stage" => assigns.failure_filter,
      "category" => assigns.category_filter,
      "search" => assigns.search_term
    }
  end

  defp parse_params(params) do
    Map.merge(
      %{
        failure_filter:
          params
          |> Map.get("stage", "all")
          |> then(&if(&1 in @stage_filter_values, do: &1, else: "all")),
        category_filter:
          params
          |> Map.get("category", "all")
          |> then(&if(&1 in @category_filter_values, do: &1, else: "all")),
        search_term: params |> Map.get("search", "") |> normalize_search_term()
      },
      FlopList.pagination_assigns(params, @default_per_page, [@default_per_page])
    )
  end

  defp failures_url_query(assigns) do
    %{
      "stage" => assigns.failure_filter,
      "category" => assigns.category_filter,
      "search" => assigns.search_term,
      "per_page" => to_string(assigns.per_page)
    }
    |> Enum.reject(fn
      {"stage", "all"} -> true
      {"category", "all"} -> true
      {"per_page", value} -> value in [@default_per_page, to_string(@default_per_page)]
      {_, value} -> value in [nil, ""]
    end)
    |> Map.new()
  end

  defp assign_url_query(socket) do
    assign(socket, :url_query, failures_url_query(socket.assigns))
  end

  defp patch_path(assigns, overrides) do
    overrides_map = Enum.into(overrides, %{}, fn {key, value} -> {to_string(key), value} end)

    query =
      failures_url_query(assigns)
      |> Map.merge(overrides_map)
      |> Enum.reject(fn
        {"stage", "all"} -> true
        {"category", "all"} -> true
        {"per_page", value} -> value in [@default_per_page, to_string(@default_per_page)]
        {_, value} -> value in [nil, ""]
      end)
      |> Map.new()

    page =
      overrides
      |> Keyword.get(:page, assigns.page)
      |> Parsers.parse_int(assigns.page)
      |> max(1)

    FlopList.patch_with_page("/failures", query, page)
  end

  defp normalize_search_term(search_term) when is_binary(search_term),
    do: String.trim(search_term)

  defp normalize_search_term(_search_term), do: ""

  defp schedule_periodic_update do
    Process.send_after(self(), :update_failures_data, @update_interval)
  end

  defp format_codecs(codecs), do: Reencodarr.Formatters.codec_list(codecs)

  defp format_command_output(output) when is_binary(output) and output != "" do
    # Clean up common command output formatting issues
    output
    # Windows line endings
    |> String.replace(~r/\r\n/, "\n")
    # Old Mac line endings
    |> String.replace(~r/\r/, "\n")
  end

  defp format_command_output(_), do: ""

  defp has_command_details?(system_context) do
    command = Map.get(system_context || %{}, "command")
    output = Map.get(system_context || %{}, "full_output", "")

    !is_nil(command) or output != ""
  end

  # Compact relative time formatting for table view
  defp compact_relative_time(nil), do: "N/A"

  defp compact_relative_time(%NaiveDateTime{} = datetime) do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> compact_relative_time()
  end

  defp compact_relative_time(%DateTime{} = datetime) do
    diff_seconds = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff_seconds < 60 -> "#{diff_seconds}s"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m"
      diff_seconds < 86_400 -> "#{div(diff_seconds, 3600)}h"
      diff_seconds < 2_592_000 -> "#{div(diff_seconds, 86_400)}d"
      diff_seconds < 31_556_952 -> "#{div(diff_seconds, 2_629_746)}mo"
      true -> "#{div(diff_seconds, 31_556_952)}y"
    end
  end

  defp compact_relative_time(_), do: "N/A"

  # Get color class for failure stage
  defp stage_color(stage) do
    case stage do
      :analysis -> "bg-purple-500"
      :crf_search -> "bg-blue-500"
      :encoding -> "bg-amber-500"
      :post_process -> "bg-red-500"
      _ -> "bg-gray-500"
    end
  end
end
