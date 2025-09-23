defmodule ReencodarrWeb.FailuresLive do
  @moduledoc """
  Live dashboard for failures analysis and management.

  ## Failures Analysis Features:
  - Failed video discovery and filtering
  - Detailed failure analysis with codec, size, path information
  - Failure retry and bulk management
  - Sorting and searching capabilities

  ## Architecture Notes:
  - Uses shared LCARS components for consistent UI
  - Memory optimized with efficient queries
  - Real-time updates for failure state changes
  """

  use ReencodarrWeb, :live_view

  import Ecto.Query

  import ReencodarrWeb.UIHelpers,
    only: [
      filter_button_classes: 2,
      action_button_classes: 0,
      action_button_classes: 2,
      pagination_button_classes: 1,
      filter_tag_classes: 1
    ]

  require Logger

  alias Reencodarr.Core.Parsers
  alias Reencodarr.Media
  alias Reencodarr.Media.SharedQueries
  alias Reencodarr.Repo

  import ReencodarrWeb.LcarsComponents
  import Reencodarr.Utils

  alias Reencodarr.UIHelpers.Stardate

  @impl true
  def mount(_params, _session, socket) do
    # Standard LiveView setup
    timezone = get_in(socket.assigns, [:timezone]) || "UTC"
    current_stardate = Stardate.calculate_stardate(DateTime.utc_now())

    # Schedule stardate updates if connected
    if Phoenix.LiveView.connected?(socket) do
      Process.send_after(self(), :update_stardate, 5000)
    end

    socket =
      socket
      |> assign(:timezone, timezone)
      |> assign(:current_stardate, current_stardate)
      |> setup_failures_data()
      |> load_failures_data()

    {:ok, socket}
  end

  @impl true
  def handle_info(:update_stardate, socket) do
    # Update stardate and schedule next update
    Process.send_after(self(), :update_stardate, 5000)
    socket = assign(socket, :current_stardate, Stardate.calculate_stardate(DateTime.utc_now()))
    {:noreply, socket}
  end

  @impl true
  def handle_event("set_timezone", %{"timezone" => tz}, socket) do
    require Logger
    Logger.debug("Setting timezone to #{tz}")
    socket = assign(socket, :timezone, tz)
    {:noreply, socket}
  end

  @impl true
  def handle_event("timezone_change", %{"tz" => tz}, socket) do
    require Logger
    Logger.debug("Setting timezone to #{tz}")
    socket = assign(socket, :timezone, tz)
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
    <div
      id="failures-live"
      class="min-h-screen bg-black text-orange-400 font-mono lcars-screen lcars-scan-lines"
      phx-hook="TimezoneHook"
    >
      <!-- LCARS Top Frame -->
      <div class="h-12 sm:h-16 bg-gradient-to-r from-orange-500 via-yellow-400 to-red-500 relative lcars-border-gradient">
        <div class="absolute top-0 left-0 w-16 sm:w-32 h-12 sm:h-16 bg-orange-500 lcars-corner-br">
        </div>
        <div class="absolute top-0 right-0 w-16 sm:w-32 h-12 sm:h-16 bg-red-500 lcars-corner-bl">
        </div>
        <div class="flex items-center justify-center h-full px-4">
          <h1 class="text-black text-lg sm:text-2xl lcars-title text-center">
            REENCODARR OPERATIONS - FAILURES ANALYSIS
          </h1>
        </div>
      </div>
      
    <!-- Navigation -->
      <.lcars_navigation current_page={:failures} />
      
    <!-- Failures Content -->
      <div class="p-3 sm:p-6 space-y-4 sm:space-y-6">
        <!-- Failures Summary -->
        <div class="bg-gray-900 border border-orange-500 p-4 rounded">
          <h2 class="text-xl text-orange-300 font-bold mb-4">FAILURES SUMMARY</h2>
          <div class="grid grid-cols-1 md:grid-cols-3 gap-4 text-sm">
            <div class="bg-red-900 p-3 rounded">
              <div class="text-red-300 font-semibold">FAILED VIDEOS</div>
              <div class="text-2xl text-red-200">{length(@failed_videos)}</div>
            </div>
            <div class="bg-orange-900 p-3 rounded">
              <div class="text-orange-300 font-semibold">FAILURE PATTERNS</div>
              <div class="text-2xl text-orange-200">{length(@failure_patterns)}</div>
            </div>
            <div class="bg-yellow-900 p-3 rounded">
              <div class="text-yellow-300 font-semibold">RECENT FAILURES</div>
              <div class="text-2xl text-yellow-200">{@failure_stats.recent_count || 0}</div>
            </div>
          </div>
        </div>
        
    <!-- Failure Controls -->
        <!-- Failure Controls -->
        <div class="bg-gray-900 border border-orange-500 rounded p-4 mb-6">
          <h3 class="text-lg text-orange-300 font-bold mb-4">FAILURE ANALYSIS CONTROLS</h3>

          <div class="flex flex-col lg:flex-row gap-4">
            <!-- Search -->
            <div class="flex-grow">
              <form phx-change="search" class="flex gap-2">
                <input
                  type="text"
                  name="search"
                  value={@search_term}
                  placeholder="Search by file path..."
                  class="flex-grow px-3 py-2 bg-gray-800 border border-orange-700 rounded text-orange-200 placeholder-orange-600 focus:border-orange-500 focus:outline-none"
                />
              </form>
            </div>
            
    <!-- Stage Filter -->
            <div class="flex flex-wrap gap-2">
              <span class="text-orange-400 text-sm font-semibold self-center">STAGE:</span>
              <button
                phx-click="filter_failures"
                phx-value-filter="all"
                class={filter_button_classes(@failure_filter == "all", :orange)}
              >
                ALL
              </button>
              <button
                phx-click="filter_failures"
                phx-value-filter="analysis"
                class={filter_button_classes(@failure_filter == "analysis", :orange)}
              >
                ANALYSIS
              </button>
              <button
                phx-click="filter_failures"
                phx-value-filter="crf_search"
                class={filter_button_classes(@failure_filter == "crf_search", :orange)}
              >
                CRF SEARCH
              </button>
              <button
                phx-click="filter_failures"
                phx-value-filter="encoding"
                class={filter_button_classes(@failure_filter == "encoding", :orange)}
              >
                ENCODING
              </button>
              <button
                phx-click="filter_failures"
                phx-value-filter="post_process"
                class={filter_button_classes(@failure_filter == "post_process", :orange)}
              >
                POST-PROCESS
              </button>
            </div>
            
    <!-- Category Filter -->
            <div class="flex flex-wrap gap-2">
              <span class="text-orange-400 text-sm font-semibold self-center">TYPE:</span>
              <button
                phx-click="filter_category"
                phx-value-category="all"
                class={filter_button_classes(@category_filter == "all", :blue)}
              >
                ALL
              </button>
              <button
                phx-click="filter_category"
                phx-value-category="file_access"
                class={filter_button_classes(@category_filter == "file_access", :blue)}
              >
                FILE ACCESS
              </button>
              <button
                phx-click="filter_category"
                phx-value-category="process_failure"
                class={filter_button_classes(@category_filter == "process_failure", :blue)}
              >
                PROCESS
              </button>
              <button
                phx-click="filter_category"
                phx-value-category="timeout"
                class={filter_button_classes(@category_filter == "timeout", :blue)}
              >
                TIMEOUT
              </button>
              <button
                phx-click="filter_category"
                phx-value-category="codec_issues"
                class={filter_button_classes(@category_filter == "codec_issues", :blue)}
              >
                CODEC
              </button>
            </div>
          </div>
          
    <!-- Active Filters Display -->
          <%= if @failure_filter != "all" or @category_filter != "all" or @search_term != "" do %>
            <div class="mt-3 pt-3 border-t border-orange-700">
              <div class="flex flex-wrap gap-2 items-center text-xs">
                <span class="text-orange-400 font-semibold">ACTIVE FILTERS:</span>
                <%= if @failure_filter != "all" do %>
                  <span class={filter_tag_classes(:orange)}>
                    Stage: {String.upcase(@failure_filter)}
                  </span>
                <% end %>
                <%= if @category_filter != "all" do %>
                  <span class={filter_tag_classes(:blue)}>
                    Type: {String.upcase(@category_filter)}
                  </span>
                <% end %>
                <%= if @search_term != "" do %>
                  <span class={filter_tag_classes(:green)}>Search: "{@search_term}"</span>
                <% end %>
                <button phx-click="clear_filters" class={filter_tag_classes(:red)}>
                  CLEAR ALL
                </button>
              </div>
            </div>
          <% end %>
        </div>
        <!-- Failed Videos Table -->
        <div class="bg-gray-900 border border-orange-500 rounded overflow-hidden">
          <div class="p-4 border-b border-orange-500">
            <h3 class="text-lg text-orange-300 font-bold">FAILED VIDEOS</h3>
          </div>

          <%= if @failed_videos == [] do %>
            <div class="p-8 text-center text-orange-400">
              <div class="text-4xl mb-4">✅</div>
              <div class="text-lg">NO FAILURES DETECTED</div>
              <div class="text-sm text-orange-600 mt-2">
                <%= if @search_term != "" do %>
                  No failed videos match your search criteria
                <% else %>
                  All videos are processing successfully
                <% end %>
              </div>
            </div>
          <% else %>
            <!-- Mobile-first responsive table -->
            <div class="block lg:hidden">
              <!-- Mobile Card Layout -->
              <div class="space-y-2 p-4">
                <%= for video <- @failed_videos do %>
                  <div class="bg-gray-800 border border-orange-700 rounded p-3">
                    <div class="flex justify-between items-start mb-2">
                      <div class="font-mono text-sm text-orange-300">#{video.id}</div>
                      <div class="flex gap-1">
                        <button
                          phx-click="retry_failed_video"
                          phx-value-video_id={video.id}
                          class={action_button_classes(:blue, [])}
                        >
                          RETRY
                        </button>
                        <button
                          phx-click="toggle_details"
                          phx-value-video_id={video.id}
                          class={action_button_classes(:gray, [])}
                        >
                          {if video.id in @expanded_details, do: "HIDE", else: "DETAILS"}
                        </button>
                      </div>
                    </div>

                    <div class="text-sm">
                      <div class="font-semibold text-orange-200 truncate" title={video.path}>
                        {Path.basename(video.path)}
                      </div>
                      <div class="text-xs text-orange-600 truncate">
                        {Path.dirname(video.path)}
                      </div>
                    </div>

                    <div class="mt-2 flex flex-wrap gap-2 text-xs">
                      <%= if video.size do %>
                        <span class={filter_tag_classes(:gray)}>
                          {Reencodarr.Formatters.file_size(video.size)}
                        </span>
                      <% end %>
                      <%= if video.video_codecs && length(video.video_codecs) > 0 do %>
                        <span class={filter_tag_classes(:dark_blue)}>
                          V: {format_codecs(video.video_codecs)}
                        </span>
                      <% end %>
                      <%= if video.audio_codecs && length(video.audio_codecs) > 0 do %>
                        <span class={filter_tag_classes(:dark_green)}>
                          A: {format_codecs(video.audio_codecs)}
                        </span>
                      <% end %>
                    </div>

                    <%= case Map.get(@video_failures, video.id) do %>
                      <% failures when is_list(failures) and length(failures) > 0 -> %>
                        <div class="mt-2">
                          <%= for failure <- Enum.take(failures, 1) do %>
                            <div class={filter_tag_classes(:red) <> " text-xs"}>
                              <div class="font-semibold">
                                {failure.failure_stage}/{failure.failure_category}
                              </div>
                              <div class="text-red-300 truncate">{failure.failure_message}</div>
                              <%= if has_command_details?(failure.system_context) do %>
                                <div class="text-red-400 text-xs mt-1">
                                  💻 Command details available
                                </div>
                              <% end %>
                            </div>
                          <% end %>
                          <%= if length(failures) > 1 do %>
                            <div class="text-xs text-orange-600 mt-1">
                              +{length(failures) - 1} more failures
                            </div>
                          <% end %>
                        </div>
                      <% _ -> %>
                        <div class="mt-2 text-xs text-orange-600">No specific failures recorded</div>
                    <% end %>
                    
    <!-- Mobile expanded details -->
                    <%= if video.id in @expanded_details do %>
                      <div class="mt-3 pt-3 border-t border-orange-700">
                        <div class="space-y-2">
                          <div>
                            <h5 class="text-xs font-semibold text-orange-300 mb-1">VIDEO DETAILS</h5>
                            <div class="grid grid-cols-2 gap-2 text-xs">
                              <div>
                                <strong>Bitrate:</strong> {if video.bitrate,
                                  do: "#{video.bitrate} bps",
                                  else: "Unknown"}
                              </div>
                              <div>
                                <strong>Duration:</strong> {if video.duration,
                                  do: "#{Float.round(video.duration / 60, 1)} min",
                                  else: "Unknown"}
                              </div>
                              <div>
                                <strong>Resolution:</strong> {if video.width && video.height,
                                  do: "#{video.width}x#{video.height}",
                                  else: "Unknown"}
                              </div>
                              <div><strong>Service:</strong> {video.service_type}</div>
                            </div>
                          </div>
                          <%= case Map.get(@video_failures, video.id) do %>
                            <% failures when is_list(failures) and length(failures) > 0 -> %>
                              <div>
                                <h5 class="text-xs font-semibold text-orange-300 mb-1">
                                  ALL FAILURES
                                </h5>
                                <div class="space-y-1">
                                  <%= for failure <- failures do %>
                                    <div class="bg-red-900 p-2 rounded text-xs">
                                      <div class="font-semibold text-red-200">
                                        {failure.failure_stage} / {failure.failure_category}
                                        {if failure.failure_code, do: " (#{failure.failure_code})"}
                                      </div>
                                      <div class="text-red-300">{failure.failure_message}</div>
                                      
    <!-- Command and Output Details -->
                                      <%= if Map.get(failure.system_context || %{}, "command") do %>
                                        <div class="mt-2 pt-2 border-t border-red-700">
                                          <div class="text-red-200 text-xs font-semibold mb-1">
                                            COMMAND:
                                          </div>
                                          <div class="bg-black p-2 rounded font-mono text-xs text-green-400 overflow-x-auto">
                                            {Map.get(failure.system_context, "command")}
                                          </div>
                                        </div>
                                      <% end %>

                                      <%= if has_command_details?(failure.system_context) do %>
                                        <div class="mt-2 pt-2 border-t border-red-700">
                                          <div class="text-red-200 text-xs font-semibold mb-1">
                                            COMMAND OUTPUT:
                                          </div>
                                          <div class="bg-black p-2 rounded font-mono text-xs text-orange-300 overflow-x-auto max-h-40 overflow-y-auto whitespace-pre-wrap">
                                            {format_command_output(
                                              Map.get(failure.system_context, "full_output")
                                            )}
                                          </div>
                                        </div>
                                      <% end %>

                                      <div class="text-red-400 text-xs mt-2">
                                        {Calendar.strftime(failure.inserted_at, "%m/%d %H:%M")}
                                      </div>
                                    </div>
                                  <% end %>
                                </div>
                              </div>
                            <% _ -> %>
                              <div class="text-orange-600 text-xs">
                                No detailed failure information available
                              </div>
                          <% end %>
                        </div>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
            
    <!-- Desktop Table Layout -->
            <div class="hidden lg:block overflow-x-auto">
              <table class="w-full">
                <thead class="bg-orange-500 text-black">
                  <tr>
                    <th class="px-3 py-2 text-left text-xs font-semibold">ID</th>
                    <th class="px-3 py-2 text-left text-xs font-semibold">FILE</th>
                    <th class="px-3 py-2 text-left text-xs font-semibold">SIZE</th>
                    <th class="px-3 py-2 text-left text-xs font-semibold">CODECS</th>
                    <th class="px-3 py-2 text-left text-xs font-semibold">LATEST FAILURE</th>
                    <th class="px-3 py-2 text-left text-xs font-semibold">ACTIONS</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for video <- @failed_videos do %>
                    <tr class="border-b border-orange-700 hover:bg-gray-800">
                      <td class="px-3 py-3 text-sm font-mono text-orange-300">{video.id}</td>
                      <td class="px-3 py-3 text-sm max-w-xs">
                        <div class="font-semibold truncate" title={video.path}>
                          {Path.basename(video.path)}
                        </div>
                        <div class="text-xs text-orange-600 truncate">
                          .../{video.path |> String.split("/") |> Enum.take(-2) |> Enum.join("/")}
                        </div>
                      </td>
                      <td class="px-3 py-3 text-sm">
                        <%= if video.size do %>
                          {Reencodarr.Formatters.file_size(video.size)}
                        <% else %>
                          <span class="text-orange-600">Unknown</span>
                        <% end %>
                      </td>
                      <td class="px-3 py-3 text-sm">
                        <div class="text-xs space-y-1">
                          <div>
                            <span class="text-blue-400">V:</span> {format_codecs(video.video_codecs)}
                          </div>
                          <div>
                            <span class="text-green-400">A:</span> {format_codecs(video.audio_codecs)}
                          </div>
                        </div>
                      </td>
                      <td class="px-3 py-3 text-sm max-w-xs">
                        <%= case Map.get(@video_failures, video.id) do %>
                          <% failures when is_list(failures) and length(failures) > 0 -> %>
                            <% latest_failure = List.first(failures) %>
                            <div class={filter_tag_classes(:red) <> " text-xs"}>
                              <div class="font-semibold text-red-200">
                                {latest_failure.failure_stage}/{latest_failure.failure_category}
                              </div>
                              <div
                                class="text-red-300 truncate"
                                title={latest_failure.failure_message}
                              >
                                {latest_failure.failure_message}
                              </div>
                              <%= if has_command_details?(latest_failure.system_context) do %>
                                <div class="text-red-400 text-xs mt-1">
                                  💻 Command details available
                                </div>
                              <% end %>
                            </div>
                            <%= if length(failures) > 1 do %>
                              <div class="text-xs text-orange-600 mt-1">
                                +{length(failures) - 1} more
                              </div>
                            <% end %>
                          <% _ -> %>
                            <span class="text-orange-600 text-xs">No specific failures recorded</span>
                        <% end %>
                      </td>
                      <td class="px-3 py-3 text-sm">
                        <div class="flex gap-1">
                          <button
                            phx-click="retry_failed_video"
                            phx-value-video_id={video.id}
                            class={action_button_classes(:blue, [])}
                          >
                            RETRY
                          </button>
                          <button
                            phx-click="toggle_details"
                            phx-value-video_id={video.id}
                            class={action_button_classes(:gray, [])}
                          >
                            {if video.id in @expanded_details, do: "HIDE", else: "DETAILS"}
                          </button>
                        </div>
                      </td>
                    </tr>
                    <%= if video.id in @expanded_details do %>
                      <tr class="bg-gray-800">
                        <td colspan="6" class="px-3 py-4">
                          <div class="space-y-3">
                            <div>
                              <h5 class="text-sm font-semibold text-orange-300 mb-2">
                                VIDEO DETAILS
                              </h5>
                              <div class="grid grid-cols-2 md:grid-cols-4 gap-2 text-xs">
                                <div>
                                  <strong>Bitrate:</strong> {if video.bitrate,
                                    do: "#{video.bitrate} bps",
                                    else: "Unknown"}
                                </div>
                                <div>
                                  <strong>Duration:</strong> {if video.duration,
                                    do: "#{Float.round(video.duration / 60, 1)} min",
                                    else: "Unknown"}
                                </div>
                                <div>
                                  <strong>Resolution:</strong> {if video.width && video.height,
                                    do: "#{video.width}x#{video.height}",
                                    else: "Unknown"}
                                </div>
                                <div><strong>Service:</strong> {video.service_type}</div>
                              </div>
                            </div>
                            <%= case Map.get(@video_failures, video.id) do %>
                              <% failures when is_list(failures) and length(failures) > 0 -> %>
                                <div>
                                  <h5 class="text-sm font-semibold text-orange-300 mb-2">
                                    FAILURE DETAILS
                                  </h5>
                                  <div class="space-y-2">
                                    <%= for failure <- failures do %>
                                      <div class="bg-red-900 p-3 rounded text-xs">
                                        <div class="font-semibold text-red-200">
                                          {failure.failure_stage} / {failure.failure_category}
                                          {if failure.failure_code, do: " (#{failure.failure_code})"}
                                        </div>
                                        <div class="text-red-300 mt-1">{failure.failure_message}</div>
                                        
    <!-- Command and Output Details -->
                                        <%= if Map.get(failure.system_context || %{}, "command") do %>
                                          <div class="mt-3 pt-2 border-t border-red-700">
                                            <div class="text-red-200 text-xs font-semibold mb-2">
                                              EXECUTED COMMAND:
                                            </div>
                                            <div class="bg-black p-3 rounded font-mono text-xs text-green-400 overflow-x-auto">
                                              {Map.get(failure.system_context, "command")}
                                            </div>
                                          </div>
                                        <% end %>

                                        <%= if has_command_details?(failure.system_context) do %>
                                          <div class="mt-3 pt-2 border-t border-red-700">
                                            <div class="text-red-200 text-xs font-semibold mb-2">
                                              FULL COMMAND OUTPUT:
                                            </div>
                                            <div class="bg-black p-3 rounded font-mono text-xs text-orange-300 overflow-x-auto max-h-60 overflow-y-auto whitespace-pre-wrap">
                                              {format_command_output(
                                                Map.get(failure.system_context, "full_output")
                                              )}
                                            </div>
                                          </div>
                                        <% end %>

                                        <div class="text-red-400 mt-3">
                                          {Calendar.strftime(
                                            failure.inserted_at,
                                            "%Y-%m-%d %H:%M:%S UTC"
                                          )}
                                        </div>
                                      </div>
                                    <% end %>
                                  </div>
                                </div>
                              <% _ -> %>
                                <div class="text-orange-600 text-sm">
                                  No detailed failure information available
                                </div>
                            <% end %>
                          </div>
                        </td>
                      </tr>
                    <% end %>
                  <% end %>
                </tbody>
              </table>
            </div>
            
    <!-- Pagination -->
            <%= if @total_pages > 1 do %>
              <div class="p-4 border-t border-orange-500 bg-gray-800">
                <div class="flex flex-col sm:flex-row items-center justify-between gap-2">
                  <div class="text-xs text-orange-600">
                    Page {@page} of {@total_pages}
                  </div>

                  <div class="flex gap-1">
                    <!-- First Page -->
                    <%= if @page > 1 do %>
                      <button
                        phx-click="change_page"
                        phx-value-page="1"
                        class={action_button_classes()}
                      >
                        ««
                      </button>
                    <% end %>
                    
    <!-- Previous Page -->
                    <%= if @page > 1 do %>
                      <button
                        phx-click="change_page"
                        phx-value-page={@page - 1}
                        class={action_button_classes()}
                      >
                        ‹
                      </button>
                    <% end %>
                    
    <!-- Page Numbers -->
                    <%= for page_num <- pagination_range(@page, @total_pages) do %>
                      <button
                        phx-click="change_page"
                        phx-value-page={page_num}
                        class={pagination_button_classes(page_num == @page)}
                      >
                        {page_num}
                      </button>
                    <% end %>
                    
    <!-- Next Page -->
                    <%= if @page < @total_pages do %>
                      <button
                        phx-click="change_page"
                        phx-value-page={@page + 1}
                        class={action_button_classes()}
                      >
                        ›
                      </button>
                    <% end %>
                    
    <!-- Last Page -->
                    <%= if @page < @total_pages do %>
                      <button
                        phx-click="change_page"
                        phx-value-page={@total_pages}
                        class={action_button_classes()}
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
          <div class="bg-gray-900 border border-orange-500 rounded">
            <div class="p-4 border-b border-orange-500">
              <h3 class="text-lg text-orange-300 font-bold">COMMON FAILURE PATTERNS</h3>
            </div>
            <div class="p-4">
              <div class="space-y-3">
                <%= for pattern <- @failure_patterns do %>
                  <div class="bg-yellow-900 p-3 rounded">
                    <div class="flex justify-between items-start">
                      <div>
                        <div class="font-semibold text-yellow-200">
                          {pattern.stage}/{pattern.category}
                          {if pattern.code, do: "(#{pattern.code})"}
                        </div>
                        <div class="text-yellow-300 text-sm mt-1">{pattern.sample_message}</div>
                      </div>
                      <div class="text-right text-yellow-200">
                        <div class="font-bold">{pattern.count} occurrences</div>
                        <div class="text-xs">
                          Latest: {Calendar.strftime(pattern.latest_occurrence, "%m/%d %H:%M")}
                        </div>
                      </div>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        <% end %>
        
    <!-- LCARS Bottom Frame -->
        <div class="h-6 sm:h-8 bg-gradient-to-r from-red-500 via-yellow-400 to-orange-500 rounded">
          <div class="flex items-center justify-center h-full">
            <span class="text-black lcars-label text-xs sm:text-sm">
              STARDATE {@current_stardate}
            </span>
          </div>
        </div>
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

  defp format_codecs(nil), do: "Unknown"
  defp format_codecs([]), do: "None"

  defp format_codecs(codecs) when is_non_empty_list(codecs) do
    codecs |> Enum.take(2) |> Enum.join(", ")
  end

  defp format_codecs(_), do: "Unknown"

  defp pagination_range(current_page, total_pages) do
    start_page = max(1, current_page - 2)
    end_page = min(total_pages, current_page + 2)
    Enum.to_list(start_page..end_page)
  end

  defp format_command_output(output) when is_non_empty_binary(output) do
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

  # CSS helper functions
  # Helper functions use UIHelpers directly
  import ReencodarrWeb.UIHelpers,
    only: [
      filter_button_classes: 2,
      action_button_classes: 0,
      pagination_button_classes: 1
    ]
end
