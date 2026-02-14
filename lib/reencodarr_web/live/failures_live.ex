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

  import Ecto.Query

  require Logger

  alias Reencodarr.Core.Parsers
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Media
  alias Reencodarr.Media.SharedQueries
  alias Reencodarr.Repo

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> setup_failures_data()
      |> assign_placeholder_data()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())
      schedule_periodic_update()
      # Load data asynchronously to avoid blocking mount
      send(self(), :load_initial_data)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:load_initial_data, socket) do
    {:noreply, load_failures_data(socket)}
  end

  @impl true
  def handle_info(:update_failures_data, socket) do
    schedule_periodic_update()
    {:noreply, load_failures_data(socket)}
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
    socket = load_failures_data(socket)
    {:noreply, socket}
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
            socket = load_failures_data(socket)
            {:noreply, put_flash(socket, :info, "Video #{video.id} marked for retry")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Invalid video ID")}
    end
  end

  @impl true
  def handle_event("reset_all_failures", _params, socket) do
    # Reset all failed videos
    Media.reset_failed_videos()

    # Reload the failures data
    socket = load_failures_data(socket)
    {:noreply, put_flash(socket, :info, "All failed videos have been reset")}
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
        |> load_failures_data()

      count = Enum.count(selected_ids)
      {:noreply, put_flash(socket, :info, "Retrying #{count} selected videos")}
    end
  end

  @impl true
  def handle_event("filter_failures", %{"filter" => filter}, socket) do
    socket =
      socket
      |> assign(:failure_filter, filter)
      # Reset to first page when filtering
      |> assign(:page, 1)
      |> load_failures_data()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_category", %{"category" => category}, socket) do
    socket =
      socket
      |> assign(:category_filter, category)
      # Reset to first page when filtering
      |> assign(:page, 1)
      |> load_failures_data()

    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    socket =
      socket
      |> assign(:failure_filter, "all")
      |> assign(:category_filter, "all")
      |> assign(:search_term, "")
      |> assign(:page, 1)
      |> load_failures_data()

    {:noreply, socket}
  end

  @impl true
  def handle_event("change_page", %{"page" => page}, socket) do
    page = Parsers.parse_int(page, 1)

    socket =
      socket
      |> assign(:page, page)
      |> load_failures_data()

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"search" => search_term}, socket) do
    socket =
      socket
      |> assign(:search_term, search_term)
      # Reset to first page when searching
      |> assign(:page, 1)
      |> load_failures_data()

    {:noreply, socket}
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
    <div class="min-h-screen bg-gray-900 p-6">
      <div class="max-w-7xl mx-auto space-y-6">
        <!-- Header -->
        <div class="flex justify-between items-start">
          <div>
            <h1 class="text-3xl font-bold text-white">
              Failures ({@total_count})
            </h1>
            <p class="text-gray-400">Monitor and manage failed video processing operations</p>
          </div>
          <div class="flex gap-2">
            <%= if MapSet.size(@selected_videos) > 0 do %>
              <button
                phx-click="retry_selected"
                class="px-4 py-2 text-sm font-medium text-white bg-blue-600 rounded-lg hover:bg-blue-700 transition-colors"
              >
                Retry Selected ({MapSet.size(@selected_videos)})
              </button>
            <% end %>
            <button
              phx-click="reset_all_failures"
              class="px-4 py-2 text-sm font-medium text-white bg-red-600 rounded-lg hover:bg-red-700 transition-colors"
            >
              Reset All
            </button>
          </div>
        </div>
        
    <!-- Loading State -->
        <%= if @loading do %>
          <div class="bg-gray-800 rounded-lg shadow-lg p-12 border border-gray-700 text-center">
            <div class="animate-spin rounded-full h-12 w-12 border-b-2 border-purple-500 mx-auto mb-4">
            </div>
            <p class="text-gray-400">Loading failure data...</p>
          </div>
        <% else %>
          <!-- Integrated Toolbar: Search + Filters -->
          <div class="bg-gray-800 rounded-lg shadow-lg p-4 border border-gray-700">
            <div class="flex flex-col gap-3">
              <!-- Search Bar -->
              <form phx-change="search">
                <input
                  type="text"
                  name="search"
                  value={@search_term}
                  placeholder="🔍 Search by file path..."
                  phx-debounce="300"
                  aria-label="Search failed videos by file path"
                  class="w-full px-4 py-2 bg-gray-700 border border-gray-600 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500 text-white placeholder-gray-400"
                />
              </form>
              
    <!-- Compact Filters -->
              <div class="flex flex-col sm:flex-row gap-3">
                <!-- Stage Filter -->
                <div class="flex items-center gap-2">
                  <span class="text-sm font-medium text-gray-300 whitespace-nowrap">Stage:</span>
                  <div class="inline-flex flex-wrap gap-1" role="group" aria-label="Filter by stage">
                    <button
                      phx-click="filter_failures"
                      phx-value-filter="all"
                      class={"px-2 py-1 text-xs rounded transition-colors #{if @failure_filter == "all", do: "bg-purple-600 text-white", else: "bg-gray-700 text-gray-300 hover:bg-gray-600"}"}
                    >
                      All
                    </button>
                    <button
                      phx-click="filter_failures"
                      phx-value-filter="analysis"
                      class={"px-2 py-1 text-xs rounded transition-colors #{if @failure_filter == "analysis", do: "bg-purple-600 text-white", else: "bg-gray-700 text-gray-300 hover:bg-gray-600"}"}
                    >
                      Analysis
                    </button>
                    <button
                      phx-click="filter_failures"
                      phx-value-filter="crf_search"
                      class={"px-2 py-1 text-xs rounded transition-colors #{if @failure_filter == "crf_search", do: "bg-blue-600 text-white", else: "bg-gray-700 text-gray-300 hover:bg-gray-600"}"}
                    >
                      CRF
                    </button>
                    <button
                      phx-click="filter_failures"
                      phx-value-filter="encoding"
                      class={"px-2 py-1 text-xs rounded transition-colors #{if @failure_filter == "encoding", do: "bg-amber-600 text-white", else: "bg-gray-700 text-gray-300 hover:bg-gray-600"}"}
                    >
                      Encoding
                    </button>
                    <button
                      phx-click="filter_failures"
                      phx-value-filter="post_process"
                      class={"px-2 py-1 text-xs rounded transition-colors #{if @failure_filter == "post_process", do: "bg-red-600 text-white", else: "bg-gray-700 text-gray-300 hover:bg-gray-600"}"}
                    >
                      Post
                    </button>
                  </div>
                </div>
                
    <!-- Category Filter -->
                <div class="flex items-center gap-2">
                  <span class="text-sm font-medium text-gray-300 whitespace-nowrap">Type:</span>
                  <div
                    class="inline-flex flex-wrap gap-1"
                    role="group"
                    aria-label="Filter by category"
                  >
                    <button
                      phx-click="filter_category"
                      phx-value-category="all"
                      class={"px-2 py-1 text-xs rounded transition-colors #{if @category_filter == "all", do: "bg-green-600 text-white", else: "bg-gray-700 text-gray-300 hover:bg-gray-600"}"}
                    >
                      All
                    </button>
                    <button
                      phx-click="filter_category"
                      phx-value-category="process_failure"
                      class={"px-2 py-1 text-xs rounded transition-colors #{if @category_filter == "process_failure", do: "bg-green-600 text-white", else: "bg-gray-700 text-gray-300 hover:bg-gray-600"}"}
                    >
                      Process
                    </button>
                    <button
                      phx-click="filter_category"
                      phx-value-category="timeout"
                      class={"px-2 py-1 text-xs rounded transition-colors #{if @category_filter == "timeout", do: "bg-green-600 text-white", else: "bg-gray-700 text-gray-300 hover:bg-gray-600"}"}
                    >
                      Timeout
                    </button>
                    <button
                      phx-click="filter_category"
                      phx-value-category="codec_issues"
                      class={"px-2 py-1 text-xs rounded transition-colors #{if @category_filter == "codec_issues", do: "bg-green-600 text-white", else: "bg-gray-700 text-gray-300 hover:bg-gray-600"}"}
                    >
                      Codec
                    </button>
                    <button
                      phx-click="filter_category"
                      phx-value-category="file_access"
                      class={"px-2 py-1 text-xs rounded transition-colors #{if @category_filter == "file_access", do: "bg-green-600 text-white", else: "bg-gray-700 text-gray-300 hover:bg-gray-600"}"}
                    >
                      File
                    </button>
                  </div>
                </div>
              </div>
            </div>
          </div>
          
    <!-- Failed Videos Table -->
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
              <!-- Table -->
              <div class="divide-y divide-gray-700">
                <!-- Table Header -->
                <div class="grid grid-cols-[auto_1fr_auto_auto_auto_auto] gap-4 px-4 py-3 bg-gray-750 text-xs font-semibold text-gray-400 uppercase tracking-wider">
                  <div class="flex items-center">
                    <%= if MapSet.size(@selected_videos) == length(@failed_videos) and length(@failed_videos) > 0 do %>
                      <input
                        type="checkbox"
                        checked
                        phx-click="deselect_all"
                        class="w-4 h-4 text-blue-600 bg-gray-700 border-gray-600 rounded focus:ring-blue-500 cursor-pointer"
                      />
                    <% else %>
                      <input
                        type="checkbox"
                        phx-click="select_all"
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
                
    <!-- Table Rows -->
                <%= for video <- @failed_videos do %>
                  <% latest_failure =
                    Map.get(@video_failures, video.id)
                    |> then(fn
                      failures when is_list(failures) and failures != [] -> List.first(failures)
                      _ -> nil
                    end) %>
                  
    <!-- Row (clickable) -->
                  <div class="hover:bg-gray-750">
                    <div
                      phx-click="toggle_details"
                      phx-value-video_id={video.id}
                      class="grid grid-cols-[auto_1fr_auto_auto_auto_auto] gap-4 px-4 py-3 cursor-pointer"
                    >
                      <!-- Column 1: Checkbox -->
                      <div
                        class="flex items-center"
                        phx-click="toggle_select"
                        phx-value-video_id={video.id}
                        phx-click-away=""
                      >
                        <input
                          type="checkbox"
                          checked={MapSet.member?(@selected_videos, video.id)}
                          class="w-4 h-4 text-blue-600 bg-gray-700 border-gray-600 rounded focus:ring-blue-500 cursor-pointer pointer-events-none"
                        />
                      </div>
                      
    <!-- Column 2: Video Info -->
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
                      
    <!-- Column 3: Size -->
                      <div class="flex items-center text-sm text-gray-300">
                        <%= if video.size do %>
                          {Reencodarr.Formatters.file_size(video.size)}
                        <% else %>
                          <span class="text-gray-500">—</span>
                        <% end %>
                      </div>
                      
    <!-- Column 4: Error (with stage dot) -->
                      <div class="flex items-center min-w-0">
                        <%= if latest_failure do %>
                          <div class="flex items-start gap-2">
                            <div class={"w-2 h-2 rounded-full mt-1.5 flex-shrink-0 #{stage_color(latest_failure.failure_stage)}"}>
                            </div>
                            <div class="min-w-0">
                              <div class="text-xs font-semibold text-white">
                                {latest_failure.failure_stage}
                              </div>
                              <div
                                class="text-xs text-gray-400 truncate"
                                title={latest_failure.failure_code}
                              >
                                <%= if latest_failure.failure_code do %>
                                  {latest_failure.failure_code}
                                <% else %>
                                  {latest_failure.failure_category}
                                <% end %>
                              </div>
                              <div
                                class="text-xs text-gray-500 truncate"
                                title={latest_failure.failure_message}
                              >
                                {String.slice(latest_failure.failure_message || "", 0, 40)}{if String.length(
                                                                                                 latest_failure.failure_message ||
                                                                                                   ""
                                                                                               ) > 40,
                                                                                               do:
                                                                                                 "..."}
                              </div>
                            </div>
                          </div>
                        <% else %>
                          <span class="text-xs text-gray-500">No failure info</span>
                        <% end %>
                      </div>
                      
    <!-- Column 5: Relative Time -->
                      <div class="flex items-center text-xs text-gray-400">
                        <%= if latest_failure do %>
                          {compact_relative_time(latest_failure.inserted_at)}
                        <% else %>
                          —
                        <% end %>
                      </div>
                      
    <!-- Column 6: Retry Button -->
                      <div
                        class="flex items-center"
                        phx-click="retry_failed_video"
                        phx-value-video_id={video.id}
                        phx-click-away=""
                      >
                        <button class="px-3 py-1 text-xs font-medium text-white bg-blue-600 rounded hover:bg-blue-700 transition-colors pointer-events-none">
                          Retry
                        </button>
                      </div>
                    </div>
                    
    <!-- Expanded Details Panel -->
                    <%= if video.id in @expanded_details do %>
                      <div class="px-4 py-4 bg-gray-800/50 border-t border-gray-700">
                        <%= case Map.get(@video_failures, video.id) do %>
                          <% failures when is_list(failures) and failures != [] -> %>
                            <% latest = List.first(failures) %>
                            
    <!-- Command Block -->
                            <%= if Map.get(latest.system_context || %{}, "command") do %>
                              <div class="mb-3">
                                <div class="text-xs font-semibold text-gray-300 mb-1">Command</div>
                                <div class="bg-gray-900 p-3 rounded font-mono text-xs text-green-400 overflow-x-auto">
                                  $ {Map.get(latest.system_context, "command")}
                                </div>
                              </div>
                            <% end %>
                            
    <!-- Output Block -->
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
                            
    <!-- History Timeline -->
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
                                      {failure.failure_stage}/{failure.failure_code ||
                                        failure.failure_category} ({compact_relative_time(
                                        failure.inserted_at
                                      )})
                                    </span>
                                  <% end %>
                                </div>
                              </div>
                            <% end %>
                          <% _ -> %>
                            <div class="text-xs text-gray-400">
                              No detailed failure information available
                            </div>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
              
    <!-- Pagination -->
              <%= if @total_pages > 1 do %>
                <div class="p-4 border-t border-gray-700">
                  <div class="flex flex-col sm:flex-row items-center justify-between gap-3">
                    <div class="text-sm text-gray-400">
                      Page <span class="font-medium text-white">{@page}</span>
                      of <span class="font-medium text-white">{@total_pages}</span>
                    </div>

                    <div class="flex gap-1">
                      <%= if @page > 1 do %>
                        <button
                          phx-click="change_page"
                          phx-value-page="1"
                          class="px-3 py-1.5 text-sm font-medium text-gray-300 bg-gray-700 border border-gray-600 rounded hover:bg-gray-600 transition-colors"
                          title="First page"
                        >
                          ««
                        </button>
                        <button
                          phx-click="change_page"
                          phx-value-page={@page - 1}
                          class="px-3 py-1.5 text-sm font-medium text-gray-300 bg-gray-700 border border-gray-600 rounded hover:bg-gray-600 transition-colors"
                          title="Previous page"
                        >
                          ‹
                        </button>
                      <% end %>

                      <%= for page_num <- pagination_range(@page, @total_pages) do %>
                        <button
                          phx-click="change_page"
                          phx-value-page={page_num}
                          class={
                            if page_num == @page do
                              "px-3 py-1.5 text-sm font-medium text-white bg-blue-600 border border-blue-600 rounded"
                            else
                              "px-3 py-1.5 text-sm font-medium text-gray-300 bg-gray-700 border border-gray-600 rounded hover:bg-gray-600 transition-colors"
                            end
                          }
                        >
                          {page_num}
                        </button>
                      <% end %>

                      <%= if @page < @total_pages do %>
                        <button
                          phx-click="change_page"
                          phx-value-page={@page + 1}
                          class="px-3 py-1.5 text-sm font-medium text-gray-300 bg-gray-700 border border-gray-600 rounded hover:bg-gray-600 transition-colors"
                          title="Next page"
                        >
                          ›
                        </button>
                        <button
                          phx-click="change_page"
                          phx-value-page={@total_pages}
                          class="px-3 py-1.5 text-sm font-medium text-gray-300 bg-gray-700 border border-gray-600 rounded hover:bg-gray-600 transition-colors"
                          title="Last page"
                        >
                          »»
                        </button>
                      <% end %>
                    </div>
                  </div>
                </div>
              <% end %>
            <% end %>
          </div>
          
    <!-- Common Patterns -->
          <%= if length(@failure_patterns) > 0 do %>
            <div class="bg-gray-800 rounded-lg shadow-lg p-6 border border-gray-700">
              <h2 class="text-xl font-semibold text-white mb-4">Common Patterns</h2>
              <div class="space-y-2">
                <%= for pattern <- @failure_patterns do %>
                  <div class="flex items-center justify-between px-4 py-2 bg-gray-750 rounded">
                    <div class="flex items-center gap-3">
                      <div class={"w-2 h-2 rounded-full flex-shrink-0 #{stage_color(pattern.stage)}"}>
                      </div>
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
        <% end %>
      </div>
    </div>
    """
  end

  # Private Helper Functions

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
    |> assign(:total_count, 0)
    |> assign(:total_pages, 0)
  end

  defp load_failures_data(socket) do
    # Get pagination info
    page = socket.assigns.page
    per_page = socket.assigns.per_page
    filter = socket.assigns.failure_filter
    category_filter = socket.assigns.category_filter
    search_term = socket.assigns.search_term

    # Get failed videos with pagination and filtering
    {failed_videos, total_count} =
      get_failed_videos_paginated(page, per_page, filter, category_filter, search_term)

    # Get failure details for current page videos
    video_failures = get_failures_by_video(failed_videos)

    # Get failure statistics and patterns
    failure_stats = Media.get_failure_statistics(days_back: 7)
    failure_patterns = Media.get_common_failure_patterns(5)

    # Calculate pagination info
    total_pages = ceil(total_count / per_page)

    socket
    |> assign(:loading, false)
    |> assign(:failed_videos, failed_videos)
    |> assign(:video_failures, video_failures)
    |> assign(:failure_stats, summarize_failure_stats(failure_stats))
    |> assign(:failure_patterns, failure_patterns)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, total_pages)
  end

  defp get_failed_videos_paginated(page, per_page, stage_filter, category_filter, search_term) do
    import Ecto.Query

    base_query = from(v in Reencodarr.Media.Video, where: v.state == :failed)

    base_query
    |> apply_failure_filters(stage_filter, category_filter)
    |> apply_search_filter(search_term)
    |> apply_ordering()
    |> get_paginated_results(page, per_page)
  end

  defp apply_failure_filters(base_query, stage_filter, category_filter) do
    if stage_filter != "all" or category_filter != "all" do
      query =
        from v in base_query,
          join: f in Reencodarr.Media.VideoFailure,
          on: f.video_id == v.id,
          where: f.resolved == false,
          distinct: true

      query
      |> apply_stage_filter(stage_filter)
      |> apply_category_filter(category_filter)
    else
      base_query
    end
  end

  defp apply_stage_filter(query, "all"), do: query

  defp apply_stage_filter(query, stage_filter) do
    case parse_stage_filter(stage_filter) do
      {:ok, stage_atom} ->
        from [v, f] in query, where: f.failure_stage == ^stage_atom

      {:error, _reason} ->
        # Invalid stage filter, return no results
        from [v, f] in query, where: false
    end
  end

  defp apply_category_filter(query, "all"), do: query

  defp apply_category_filter(query, category_filter) do
    case parse_category_filter(category_filter) do
      {:ok, category_atom} ->
        from [v, f] in query, where: f.failure_category == ^category_atom

      {:error, _reason} ->
        # Invalid category filter, return no results
        from [v, f] in query, where: false
    end
  end

  defp parse_stage_filter("analysis"), do: {:ok, :analysis}
  defp parse_stage_filter("crf_search"), do: {:ok, :crf_search}
  defp parse_stage_filter("encoding"), do: {:ok, :encoding}
  defp parse_stage_filter("post_process"), do: {:ok, :post_process}
  defp parse_stage_filter(invalid), do: {:error, "Invalid stage filter: #{inspect(invalid)}"}

  defp parse_category_filter("file_access"), do: {:ok, :file_access}
  defp parse_category_filter("process_failure"), do: {:ok, :process_failure}
  defp parse_category_filter("timeout"), do: {:ok, :timeout}
  defp parse_category_filter("codec_issues"), do: {:ok, :codec_issues}

  defp parse_category_filter(invalid),
    do: {:error, "Invalid category filter: #{inspect(invalid)}"}

  defp apply_search_filter(query, ""), do: query

  defp apply_search_filter(query, search_term) do
    search_pattern = "%#{search_term}%"
    case_insensitive_like_condition = SharedQueries.case_insensitive_like(:path, search_pattern)
    from v in query, where: ^case_insensitive_like_condition
  end

  defp apply_ordering(query) do
    from v in query, order_by: [desc: v.inserted_at]
  end

  defp get_paginated_results(query, page, per_page) do
    total_count = get_total_count(query)
    offset = (page - 1) * per_page
    videos = Repo.all(from v in query, limit: ^per_page, offset: ^offset)
    {videos, total_count}
  end

  defp get_total_count(query) do
    case has_group_by?(query) do
      true ->
        # When we have GROUP BY, we need to count the grouped results
        subquery = from v in query, select: v.id
        Repo.all(subquery) |> length()

      false ->
        # No GROUP BY, safe to use aggregate
        Repo.aggregate(query, :count, :id)
    end
  end

  # Helper function to check if a query has GROUP BY clause
  defp has_group_by?(%Ecto.Query{group_bys: group_bys}), do: not Enum.empty?(group_bys)

  defp get_failures_by_video(videos) do
    import Ecto.Query
    video_ids = Enum.map(videos, & &1.id)

    from(f in Reencodarr.Media.VideoFailure,
      where: f.video_id in ^video_ids and f.resolved == false,
      order_by: [desc: f.inserted_at]
    )
    |> Reencodarr.Repo.all()
    |> Enum.group_by(& &1.video_id)
  end

  defp summarize_failure_stats(stats) do
    recent_count =
      Enum.reduce(stats, 0, fn stat, acc ->
        acc + (stat.count || 0)
      end)

    %{recent_count: recent_count}
  end

  defp format_codecs(codecs), do: Reencodarr.Formatters.codec_list(codecs)

  defp pagination_range(current_page, total_pages) do
    start_page = max(1, current_page - 2)
    end_page = min(total_pages, current_page + 2)
    Enum.to_list(start_page..end_page)
  end

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

  # Private helper to schedule periodic data updates
  defp schedule_periodic_update do
    Process.send_after(self(), :update_failures_data, 5_000)
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
