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
      |> load_failures_data()

    # Setup subscriptions and periodic updates if connected
    if connected?(socket) do
      # Subscribe to dashboard events for real-time updates
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())
      # Start periodic data refresh
      schedule_periodic_update()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:update_failures_data, socket) do
    # Reload failures data periodically
    schedule_periodic_update()
    socket = load_failures_data(socket)
    {:noreply, socket}
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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-100 p-6">
      <div class="max-w-7xl mx-auto space-y-6">
        <!-- Header -->
        <div class="flex justify-between items-start">
          <div>
            <h1 class="text-3xl font-bold text-gray-900">Failure Analysis Dashboard</h1>
            <p class="text-gray-600">Monitor and manage failed video processing operations</p>
          </div>
          <.link
            navigate={~p"/"}
            class="bg-blue-500 hover:bg-blue-600 text-white font-semibold py-2 px-4 rounded-lg shadow transition-colors flex items-center gap-2"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="h-5 w-5"
              viewBox="0 0 20 20"
              fill="currentColor"
            >
              <path
                d="M10.707 2.293a1 1 0 00-1.414 0l-7 7a1 1 0 001.414 1.414L4 10.414V17a1 1 0 001 1h2a1 1 0 001-1v-2a1 1 0 011-1h2a1 1 0 011 1v2a1 1 0 001 1h2a1 1 0 001-1v-6.586l.293.293a1 1 0 001.414-1.414l-7-7z"
              />
            </svg>
            Back to Dashboard
          </.link>
        </div>
        
    <!-- Failures Summary -->
        <div class="bg-white rounded-lg shadow-lg p-6">
          <h2 class="text-xl font-semibold text-gray-900 mb-4">Failure Summary</h2>
          <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
            <div class="text-center">
              <div class="text-red-600 text-sm font-semibold mb-2">Failed Videos</div>
              <div class="text-4xl font-bold text-gray-900">{length(@failed_videos)}</div>
              <div class="text-xs text-gray-500 mt-1">Total failures</div>
            </div>
            <div class="text-center">
              <div class="text-orange-600 text-sm font-semibold mb-2">Failure Patterns</div>
              <div class="text-4xl font-bold text-gray-900">{length(@failure_patterns)}</div>
              <div class="text-xs text-gray-500 mt-1">Unique patterns</div>
            </div>
            <div class="text-center">
              <div class="text-yellow-600 text-sm font-semibold mb-2">Recent Failures</div>
              <div class="text-4xl font-bold text-gray-900">{@failure_stats.recent_count || 0}</div>
              <div class="text-xs text-gray-500 mt-1">Last 7 days</div>
            </div>
          </div>
        </div>
        
    <!-- Filters and Search -->
        <div class="bg-white rounded-lg shadow-lg p-6">
          <h2 class="text-xl font-semibold text-gray-900 mb-4">Filters & Search</h2>

          <!-- Search Bar -->
          <div class="mb-4">
            <form phx-change="search">
              <input
                type="text"
                name="search"
                value={@search_term}
                placeholder="Search by file path..."
                class="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500 text-gray-900 placeholder-gray-500"
              />
            </form>
          </div>
          
    <!-- Filter Buttons -->
          <div class="space-y-3">
            <!-- Stage Filter -->
            <div>
              <span class="text-sm font-medium text-gray-700 mr-2">Stage:</span>
              <div class="inline-flex flex-wrap gap-2">
                <button
                  phx-click="filter_failures"
                  phx-value-filter="all"
                  class={"px-3 py-1.5 text-sm rounded-lg transition-colors #{if @failure_filter == "all", do: "bg-red-500 text-white", else: "bg-gray-200 text-gray-700 hover:bg-gray-300"}"}
                >
                  All
                </button>
                <button
                  phx-click="filter_failures"
                  phx-value-filter="analysis"
                  class={"px-3 py-1.5 text-sm rounded-lg transition-colors #{if @failure_filter == "analysis", do: "bg-red-500 text-white", else: "bg-gray-200 text-gray-700 hover:bg-gray-300"}"}
                >
                  Analysis
                </button>
                <button
                  phx-click="filter_failures"
                  phx-value-filter="crf_search"
                  class={"px-3 py-1.5 text-sm rounded-lg transition-colors #{if @failure_filter == "crf_search", do: "bg-red-500 text-white", else: "bg-gray-200 text-gray-700 hover:bg-gray-300"}"}
                >
                  CRF Search
                </button>
                <button
                  phx-click="filter_failures"
                  phx-value-filter="encoding"
                  class={"px-3 py-1.5 text-sm rounded-lg transition-colors #{if @failure_filter == "encoding", do: "bg-red-500 text-white", else: "bg-gray-200 text-gray-700 hover:bg-gray-300"}"}
                >
                  Encoding
                </button>
                <button
                  phx-click="filter_failures"
                  phx-value-filter="post_process"
                  class={"px-3 py-1.5 text-sm rounded-lg transition-colors #{if @failure_filter == "post_process", do: "bg-red-500 text-white", else: "bg-gray-200 text-gray-700 hover:bg-gray-300"}"}
                >
                  Post-Process
                </button>
              </div>
            </div>
            
    <!-- Category Filter -->
            <div>
              <span class="text-sm font-medium text-gray-700 mr-2">Type:</span>
              <div class="inline-flex flex-wrap gap-2">
                <button
                  phx-click="filter_category"
                  phx-value-category="all"
                  class={"px-3 py-1.5 text-sm rounded-lg transition-colors #{if @category_filter == "all", do: "bg-blue-500 text-white", else: "bg-gray-200 text-gray-700 hover:bg-gray-300"}"}
                >
                  All
                </button>
                <button
                  phx-click="filter_category"
                  phx-value-category="file_access"
                  class={"px-3 py-1.5 text-sm rounded-lg transition-colors #{if @category_filter == "file_access", do: "bg-blue-500 text-white", else: "bg-gray-200 text-gray-700 hover:bg-gray-300"}"}
                >
                  File Access
                </button>
                <button
                  phx-click="filter_category"
                  phx-value-category="process_failure"
                  class={"px-3 py-1.5 text-sm rounded-lg transition-colors #{if @category_filter == "process_failure", do: "bg-blue-500 text-white", else: "bg-gray-200 text-gray-700 hover:bg-gray-300"}"}
                >
                  Process
                </button>
                <button
                  phx-click="filter_category"
                  phx-value-category="timeout"
                  class={"px-3 py-1.5 text-sm rounded-lg transition-colors #{if @category_filter == "timeout", do: "bg-blue-500 text-white", else: "bg-gray-200 text-gray-700 hover:bg-gray-300"}"}
                >
                  Timeout
                </button>
                <button
                  phx-click="filter_category"
                  phx-value-category="codec_issues"
                  class={"px-3 py-1.5 text-sm rounded-lg transition-colors #{if @category_filter == "codec_issues", do: "bg-blue-500 text-white", else: "bg-gray-200 text-gray-700 hover:bg-gray-300"}"}
                >
                  Codec
                </button>
              </div>
            </div>
          </div>
          
    <!-- Active Filters Display -->
          <%= if @failure_filter != "all" or @category_filter != "all" or @search_term != "" do %>
            <div class="mt-4 pt-4 border-t border-gray-200">
              <div class="flex flex-wrap gap-2 items-center">
                <span class="text-sm font-medium text-gray-700">Active filters:</span>
                <%= if @failure_filter != "all" do %>
                  <span class="px-2 py-1 bg-red-100 text-red-800 text-xs rounded-full">
                    Stage: {@failure_filter}
                  </span>
                <% end %>
                <%= if @category_filter != "all" do %>
                  <span class="px-2 py-1 bg-blue-100 text-blue-800 text-xs rounded-full">
                    Type: {@category_filter}
                  </span>
                <% end %>
                <%= if @search_term != "" do %>
                  <span class="px-2 py-1 bg-green-100 text-green-800 text-xs rounded-full">
                    Search: "{@search_term}"
                  </span>
                <% end %>
                <button
                  phx-click="clear_filters"
                  class="px-3 py-1 bg-gray-200 hover:bg-gray-300 text-gray-700 text-xs rounded-lg transition-colors"
                >
                  Clear All
                </button>
              </div>
            </div>
          <% end %>
        </div>
        
    <!-- Failed Videos List -->
        <div class="bg-white rounded-lg shadow-lg overflow-hidden">
          <div class="p-6 border-b border-gray-200 flex justify-between items-center">
            <h2 class="text-xl font-semibold text-gray-900">Failed Videos</h2>
            <span class="text-sm text-gray-600">
              Showing {@total_count} {if @total_count == 1, do: "failure", else: "failures"}
            </span>
          </div>

          <%= if @failed_videos == [] do %>
            <div class="p-12 text-center">
              <div class="text-6xl mb-4">✅</div>
              <h3 class="text-xl font-semibold text-gray-900 mb-2">No Failures Found</h3>
              <p class="text-gray-600">
                <%= if @search_term != "" do %>
                  No failed videos match your search criteria
                <% else %>
                  All videos are processing successfully
                <% end %>
              </p>
            </div>
          <% else %>
            <!-- Video Cards -->
            <div class="p-4 space-y-4">
              <%= for video <- @failed_videos do %>
                <div class="bg-white rounded-lg shadow-lg p-4 border-l-4 border-red-500">
                  <!-- Card Header -->
                  <div class="flex flex-col sm:flex-row sm:items-start sm:justify-between gap-3 mb-3">
                    <div class="flex-1 min-w-0">
                      <div class="flex items-center gap-2 mb-1">
                        <span class="text-xs font-mono text-gray-500">ID: {video.id}</span>
                        <%= if video.service_type do %>
                          <span class="text-xs px-2 py-0.5 bg-blue-100 text-blue-700 rounded">
                            {video.service_type}
                          </span>
                        <% end %>
                      </div>
                      <h4 class="text-sm font-semibold text-gray-900 truncate" title={video.path}>
                        {Path.basename(video.path)}
                      </h4>
                      <p class="text-xs text-gray-500 truncate" title={video.path}>
                        {Path.dirname(video.path)}
                      </p>
                    </div>
                    
                    <div class="flex gap-2 flex-shrink-0">
                      <button
                        phx-click="retry_failed_video"
                        phx-value-video_id={video.id}
                        class="px-3 py-1.5 text-xs font-medium text-white bg-blue-600 rounded hover:bg-blue-700 transition-colors"
                      >
                        Retry
                      </button>
                      <button
                        phx-click="toggle_details"
                        phx-value-video_id={video.id}
                        class="px-3 py-1.5 text-xs font-medium text-gray-700 bg-gray-200 rounded hover:bg-gray-300 transition-colors"
                      >
                        {if video.id in @expanded_details, do: "Hide", else: "Details"}
                      </button>
                    </div>
                  </div>
                  
                  <!-- Video Info -->
                  <div class="flex flex-wrap gap-2 text-xs mb-3">
                    <%= if video.size do %>
                      <span class="px-2 py-1 bg-gray-100 text-gray-700 rounded">
                        {Reencodarr.Formatters.file_size(video.size)}
                      </span>
                    <% end %>
                    <%= if video.duration do %>
                      <span class="px-2 py-1 bg-gray-100 text-gray-700 rounded">
                        {Reencodarr.Formatters.duration_minutes(video.duration)}
                      </span>
                    <% end %>
                    <%= if video.width && video.height do %>
                      <span class="px-2 py-1 bg-gray-100 text-gray-700 rounded">
                        {Reencodarr.Formatters.resolution(video.width, video.height)}
                      </span>
                    <% end %>
                    <%= if video.video_codecs && length(video.video_codecs) > 0 do %>
                      <span class="px-2 py-1 bg-blue-100 text-blue-700 rounded">
                        V: {format_codecs(video.video_codecs)}
                      </span>
                    <% end %>
                    <%= if video.audio_codecs && length(video.audio_codecs) > 0 do %>
                      <span class="px-2 py-1 bg-green-100 text-green-700 rounded">
                        A: {format_codecs(video.audio_codecs)}
                      </span>
                    <% end %>
                  </div>
                  
                  <!-- Latest Failure -->
                  <%= case Map.get(@video_failures, video.id) do %>
                    <% failures when is_list(failures) and length(failures) > 0 -> %>
                      <% latest_failure = List.first(failures) %>
                      <div class="bg-red-50 border border-red-200 rounded p-3 mb-3">
                        <div class="flex items-start justify-between gap-2 mb-1">
                          <div class="text-xs font-semibold text-red-800">
                            {latest_failure.failure_stage} / {latest_failure.failure_category}
                            <%= if latest_failure.failure_code do %>
                              <span class="font-mono ml-1">({latest_failure.failure_code})</span>
                            <% end %>
                          </div>
                          <%= if has_command_details?(latest_failure.system_context) do %>
                            <span class="text-xs text-red-600" title="Command details available">
                              💻
                            </span>
                          <% end %>
                        </div>
                        <p class="text-xs text-red-700">{latest_failure.failure_message}</p>
                        <%= if length(failures) > 1 do %>
                          <p class="text-xs text-red-600 mt-2">
                            +{length(failures) - 1} additional {if length(failures) == 2, do: "failure", else: "failures"}
                          </p>
                        <% end %>
                      </div>
                    <% _ -> %>
                      <div class="bg-gray-50 border border-gray-200 rounded p-3 mb-3">
                        <p class="text-xs text-gray-600">No specific failure information recorded</p>
                      </div>
                  <% end %>
                  
                  <!-- Expanded Details -->
                  <%= if video.id in @expanded_details do %>
                    <div class="border-t pt-3 mt-3 space-y-3">
                      <!-- Video Technical Details -->
                      <div>
                        <h5 class="text-xs font-semibold text-gray-700 mb-2">Technical Details</h5>
                        <div class="grid grid-cols-2 sm:grid-cols-4 gap-2 text-xs">
                          <div>
                            <span class="text-gray-500">Bitrate:</span>
                            <span class="ml-1 text-gray-900">
                              {Reencodarr.Formatters.bitrate(video.bitrate)}
                            </span>
                          </div>
                          <div>
                            <span class="text-gray-500">Duration:</span>
                            <span class="ml-1 text-gray-900">
                              {Reencodarr.Formatters.duration_minutes(video.duration)}
                            </span>
                          </div>
                          <div>
                            <span class="text-gray-500">Resolution:</span>
                            <span class="ml-1 text-gray-900">
                              {Reencodarr.Formatters.resolution(video.width, video.height)}
                            </span>
                          </div>
                          <div>
                            <span class="text-gray-500">Service:</span>
                            <span class="ml-1 text-gray-900">{video.service_type || "Unknown"}</span>
                          </div>
                        </div>
                      </div>
                      
                      <!-- All Failures -->
                      <%= case Map.get(@video_failures, video.id) do %>
                        <% failures when is_list(failures) and length(failures) > 0 -> %>
                          <div>
                            <h5 class="text-xs font-semibold text-gray-700 mb-2">
                              All Failures ({length(failures)})
                            </h5>
                            <div class="space-y-2">
                              <%= for failure <- failures do %>
                                <div class="bg-red-50 border border-red-200 rounded p-3">
                                  <div class="flex items-start justify-between gap-2 mb-2">
                                    <div class="text-xs font-semibold text-red-800">
                                      {failure.failure_stage} / {failure.failure_category}
                                      <%= if failure.failure_code do %>
                                        <span class="font-mono ml-1">({failure.failure_code})</span>
                                      <% end %>
                                    </div>
                                    <time class="text-xs text-red-600">
                                      {Calendar.strftime(failure.inserted_at, "%m/%d %H:%M")}
                                    </time>
                                  </div>
                                  <p class="text-xs text-red-700 mb-2">{failure.failure_message}</p>
                                  
                                  <%= if Map.get(failure.system_context || %{}, "command") do %>
                                    <div class="mt-2 pt-2 border-t border-red-200">
                                      <div class="text-xs font-semibold text-red-700 mb-1">
                                        Command:
                                      </div>
                                      <div class="bg-gray-900 p-2 rounded font-mono text-xs text-green-400 overflow-x-auto">
                                        {Map.get(failure.system_context, "command")}
                                      </div>
                                    </div>
                                  <% end %>
                                  
                                  <%= if has_command_details?(failure.system_context) do %>
                                    <div class="mt-2 pt-2 border-t border-red-200">
                                      <div class="text-xs font-semibold text-red-700 mb-1">
                                        Output:
                                      </div>
                                      <div class="bg-gray-900 p-2 rounded font-mono text-xs text-orange-300 overflow-x-auto max-h-60 overflow-y-auto">
                                        <pre class="whitespace-pre-wrap">{format_command_output(
                                          Map.get(failure.system_context, "full_output")
                                        )}</pre>
                                      </div>
                                    </div>
                                  <% end %>
                                </div>
                              <% end %>
                            </div>
                          </div>
                        <% _ -> %>
                          <div class="text-xs text-gray-600">
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
              <div class="bg-white rounded-lg shadow-lg p-4 mt-4">
                <div class="flex flex-col sm:flex-row items-center justify-between gap-3">
                  <div class="text-sm text-gray-600">
                    Page <span class="font-medium text-gray-900">{@page}</span> of <span class="font-medium text-gray-900">{@total_pages}</span>
                  </div>

                  <div class="flex gap-1">
                    <%= if @page > 1 do %>
                      <button
                        phx-click="change_page"
                        phx-value-page="1"
                        class="px-3 py-1.5 text-sm font-medium text-gray-700 bg-white border border-gray-300 rounded hover:bg-gray-50 transition-colors"
                        title="First page"
                      >
                        ««
                      </button>
                      <button
                        phx-click="change_page"
                        phx-value-page={@page - 1}
                        class="px-3 py-1.5 text-sm font-medium text-gray-700 bg-white border border-gray-300 rounded hover:bg-gray-50 transition-colors"
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
                            "px-3 py-1.5 text-sm font-medium text-gray-700 bg-white border border-gray-300 rounded hover:bg-gray-50 transition-colors"
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
                        class="px-3 py-1.5 text-sm font-medium text-gray-700 bg-white border border-gray-300 rounded hover:bg-gray-50 transition-colors"
                        title="Next page"
                      >
                        ›
                      </button>
                      <button
                        phx-click="change_page"
                        phx-value-page={@total_pages}
                        class="px-3 py-1.5 text-sm font-medium text-gray-700 bg-white border border-gray-300 rounded hover:bg-gray-50 transition-colors"
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
        
    <!-- Common Failure Patterns -->
        <%= if length(@failure_patterns) > 0 do %>
          <div class="bg-white rounded-lg shadow-lg p-6">
            <h2 class="text-xl font-semibold text-gray-900 mb-4">Common Failure Patterns</h2>
            <div class="space-y-3">
              <%= for pattern <- @failure_patterns do %>
                <div class="bg-yellow-50 border border-yellow-200 rounded-lg p-4">
                  <div class="flex justify-between items-start">
                    <div class="flex-1">
                      <div class="font-semibold text-gray-900">
                        {pattern.stage}/{pattern.category}
                        {if pattern.code, do: " (#{pattern.code})"}
                      </div>
                      <p class="text-sm text-gray-700 mt-1">{pattern.sample_message}</p>
                    </div>
                    <div class="text-right ml-4">
                      <div class="text-lg font-bold text-yellow-600">{pattern.count}</div>
                      <div class="text-xs text-gray-500">occurrences</div>
                      <div class="text-xs text-gray-500 mt-1">
                        Latest: {Calendar.strftime(pattern.latest_occurrence, "%m/%d %H:%M")}
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
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
    |> assign(:page, 1)
    |> assign(:per_page, 20)
    |> assign(:search_term, "")
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
  defp parse_stage_filter(invalid), do: {:error, "Invalid stage filter: #{inspect(invalid)}"}

  defp parse_category_filter("system"), do: {:ok, :system}
  defp parse_category_filter("media"), do: {:ok, :media}
  defp parse_category_filter("network"), do: {:ok, :network}
  defp parse_category_filter("configuration"), do: {:ok, :configuration}

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
  defp has_group_by?(%Ecto.Query{group_bys: group_bys}), do: length(group_bys) > 0

  defp get_failures_by_video(videos) do
    video_ids = Enum.map(videos, & &1.id)

    failures =
      Enum.flat_map(video_ids, fn video_id ->
        Media.get_video_failures(video_id)
        |> Enum.map(&{video_id, &1})
      end)

    failures
    |> Enum.group_by(fn {video_id, _failure} -> video_id end)
    |> Enum.into(%{}, fn {video_id, failure_tuples} ->
      {video_id, Enum.map(failure_tuples, fn {_video_id, failure} -> failure end)}
    end)
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
end
