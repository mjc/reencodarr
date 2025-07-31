defmodule ReencodarrWeb.FailuresLive do
  @moduledoc """
  Live view for failure analysis and debugging.

  Provides comprehensive failure tracking and analysis including:
  - Failure log with filtering and search
  - Failure statistics and trends
  - Detailed failure information and system context
  - Resolution tracking and retry management
  """

  use ReencodarrWeb, :live_view

  require Logger

  alias Reencodarr.{Media, Repo}

  @impl true
  def mount(_params, _session, socket) do
    # Start timer for stardate updates (every 5 seconds)
    if connected?(socket) do
      Process.send_after(self(), :update_stardate, 5000)
    end

    timezone = socket.assigns[:timezone] || "UTC"

    socket =
      assign(socket,
        timezone: timezone,
        current_stardate: calculate_stardate(DateTime.utc_now()),
        # Failures tab state
        failures_page: 1,
        failures_per_page: 20,
        failures_sort_by: :inserted_at,
        failures_sort_dir: :desc,
        failures_filter: %{},
        expanded_failure_id: nil
      )

    {:ok, socket}
  end

  @impl true
  def handle_info(:update_stardate, socket) do
    # Update the stardate and schedule the next update
    Process.send_after(self(), :update_stardate, 5000)

    socket = assign(socket, :current_stardate, calculate_stardate(DateTime.utc_now()))
    {:noreply, socket}
  end

  @impl true
  def handle_event("set_timezone", %{"timezone" => tz}, socket) do
    Logger.debug("Setting timezone to #{tz}")
    {:noreply, assign(socket, timezone: tz)}
  end

  @impl true
  def handle_event("failures_page", %{"page" => page}, socket) do
    page = String.to_integer(page)
    {:noreply, assign(socket, :failures_page, page)}
  end

  @impl true
  def handle_event("failures_sort", %{"sort_by" => sort_by}, socket) do
    sort_by = String.to_existing_atom(sort_by)

    # Toggle direction if clicking the same column
    sort_dir =
      if socket.assigns.failures_sort_by == sort_by do
        case socket.assigns.failures_sort_dir do
          :asc -> :desc
          :desc -> :asc
        end
      else
        :desc
      end

    {:noreply, assign(socket, failures_sort_by: sort_by, failures_sort_dir: sort_dir)}
  end

  @impl true
  def handle_event("failures_filter", params, socket) do
    filter =
      %{
        stage: params["stage"],
        category: params["category"],
        video_search: params["video_search"]
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Enum.into(%{})

    {:noreply, assign(socket, failures_filter: filter, failures_page: 1)}
  end

  @impl true
  def handle_event("toggle_failure_details", %{"failure_id" => failure_id}, socket) do
    failure_id = String.to_integer(failure_id)

    # Toggle: if already expanded, collapse; if collapsed, expand
    new_expanded_id =
      if socket.assigns.expanded_failure_id == failure_id do
        nil
      else
        failure_id
      end

    {:noreply, assign(socket, expanded_failure_id: new_expanded_id)}
  end

  @impl true
  def render(assigns) do
    # Get failures data for rendering
    failures_data = get_failures_data(assigns)
    assigns = assign(assigns, failures_data: failures_data)

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
            FAILURE ANALYSIS CENTER
          </h1>
        </div>
      </div>
      
    <!-- Navigation -->
      <div class="border-b-2 border-orange-500 bg-gray-900">
        <div class="flex space-x-1 p-2">
          <.link
            navigate="/"
            class="px-4 py-2 text-sm font-medium text-orange-400 hover:text-orange-300 transition-colors"
          >
            ← OVERVIEW
          </.link>
          <.link
            navigate="/broadway"
            class="px-4 py-2 text-sm font-medium text-orange-400 hover:text-orange-300 transition-colors"
          >
            PIPELINE MONITOR
          </.link>
          <span class="px-4 py-2 text-sm font-medium bg-orange-500 text-black">
            FAILURES
          </span>
        </div>
      </div>
      
    <!-- Failures Content -->
      <div class="p-3 sm:p-6 space-y-4 sm:space-y-6">
        <.lcars_failures_section
          failures_page={@failures_page}
          failures_per_page={@failures_per_page}
          failures_sort_by={@failures_sort_by}
          failures_sort_dir={@failures_sort_dir}
          failures_filter={@failures_filter}
          expanded_failure_id={@expanded_failure_id}
          failures_data={@failures_data}
        />
        
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

  # Calculate a proper Star Trek TNG-style stardate using the revised convention
  # Based on TNG Writer's Guide: 1000 units = 1 year, decimal = fractional days
  # Reference: Year 2000 = Stardate 50000.0 (extrapolated from canon progression)
  defp calculate_stardate(datetime) do
    with %DateTime{} <- datetime,
         current_date = DateTime.to_date(datetime),
         current_time = DateTime.to_time(datetime),
         {:ok, day_of_year} when is_integer(day_of_year) <- {:ok, Date.day_of_year(current_date)},
         {seconds_in_day, _microseconds} <- Time.to_seconds_after_midnight(current_time) do
      # Calculate years since reference (2000 = 50000.0)
      reference_year = 2000
      current_year = current_date.year
      years_diff = current_year - reference_year

      # Calculate fractional day (0.0 to 0.9)
      day_fraction = seconds_in_day / 86_400.0

      # TNG Formula: base + (years * 1000) + (day_of_year * 1000/365.25) + (day_fraction / 10)
      base_stardate = 50_000.0
      year_component = years_diff * 1000.0
      day_component = day_of_year * (1000.0 / 365.25)
      # Decimal represents tenths of days
      fractional_component = day_fraction / 10.0

      stardate = base_stardate + year_component + day_component + fractional_component

      # Format to one decimal place, TNG style
      Float.round(stardate, 1)
    else
      _ ->
        # Fallback to a simple calculation if anything goes wrong
        # Approximate stardate for mid-2025
        75_182.5
    end
  end

  # Failures section component
  defp lcars_failures_section(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Failures Header Panel -->
      <div class="bg-gray-900 border-2 border-orange-500 rounded-lg">
        <div class="bg-orange-500 text-black px-4 py-2 font-bold">
          FAILURE ANALYSIS CENTER
        </div>
        <div class="p-4">
          <div class="grid grid-cols-1 md:grid-cols-4 gap-4 mb-4">
            <div class="bg-red-900/30 border border-red-500 rounded p-3">
              <div class="text-red-400 text-sm">TOTAL FAILURES</div>
              <div class="text-white text-xl font-bold">{@failures_data.total_count}</div>
            </div>
            <div class="bg-yellow-900/30 border border-yellow-500 rounded p-3">
              <div class="text-yellow-400 text-sm">LAST 24H</div>
              <div class="text-white text-xl font-bold">{@failures_data.recent_count}</div>
            </div>
            <div class="bg-purple-900/30 border border-purple-500 rounded p-3">
              <div class="text-purple-400 text-sm">TOP CATEGORY</div>
              <div class="text-white text-sm font-bold">{@failures_data.top_category}</div>
            </div>
            <div class="bg-blue-900/30 border border-blue-500 rounded p-3">
              <div class="text-blue-400 text-sm">RESOLUTION RATE</div>
              <div class="text-white text-xl font-bold">{@failures_data.resolution_rate}%</div>
            </div>
          </div>
        </div>
      </div>
      
    <!-- Filters Panel -->
      <div class="bg-gray-900 border-2 border-orange-500 rounded-lg">
        <div class="bg-orange-500 text-black px-4 py-2 font-bold">
          FILTERS & SEARCH
        </div>
        <div class="p-4">
          <form phx-change="failures_filter" class="grid grid-cols-1 md:grid-cols-3 gap-4">
            <div>
              <label class="block text-orange-400 text-sm mb-1">STAGE</label>
              <select
                name="stage"
                class="w-full bg-gray-800 border border-orange-500 rounded px-3 py-2 text-white"
              >
                <option value="">ALL STAGES</option>
                <option value="analysis" selected={@failures_filter[:stage] == "analysis"}>
                  ANALYSIS
                </option>
                <option value="crf_search" selected={@failures_filter[:stage] == "crf_search"}>
                  CRF SEARCH
                </option>
                <option value="encoding" selected={@failures_filter[:stage] == "encoding"}>
                  ENCODING
                </option>
                <option value="post_process" selected={@failures_filter[:stage] == "post_process"}>
                  POST PROCESS
                </option>
              </select>
            </div>
            <div>
              <label class="block text-orange-400 text-sm mb-1">CATEGORY</label>
              <select
                name="category"
                class="w-full bg-gray-800 border border-orange-500 rounded px-3 py-2 text-white"
              >
                <option value="">ALL CATEGORIES</option>
                <option value="file_access" selected={@failures_filter[:category] == "file_access"}>
                  FILE ACCESS
                </option>
                <option
                  value="resource_exhaustion"
                  selected={@failures_filter[:category] == "resource_exhaustion"}
                >
                  RESOURCE EXHAUSTION
                </option>
                <option
                  value="process_failure"
                  selected={@failures_filter[:category] == "process_failure"}
                >
                  PROCESS FAILURE
                </option>
                <option
                  value="vmaf_calculation"
                  selected={@failures_filter[:category] == "vmaf_calculation"}
                >
                  VMAF CALCULATION
                </option>
                <option
                  value="crf_optimization"
                  selected={@failures_filter[:category] == "crf_optimization"}
                >
                  CRF OPTIMIZATION
                </option>
              </select>
            </div>
            <div>
              <label class="block text-orange-400 text-sm mb-1">VIDEO SEARCH</label>
              <input
                type="text"
                name="video_search"
                value={@failures_filter[:video_search] || ""}
                placeholder="Search video title..."
                class="w-full bg-gray-800 border border-orange-500 rounded px-3 py-2 text-white placeholder-gray-500"
              />
            </div>
          </form>
        </div>
      </div>
      
    <!-- Failures Table -->
      <div class="bg-gray-900 border-2 border-orange-500 rounded-lg overflow-hidden">
        <div class="bg-orange-500 text-black px-4 py-2 font-bold">
          FAILURE LOG - PAGE {@failures_page} OF {@failures_data.total_pages}
        </div>

        <div class="overflow-x-auto">
          <table class="w-full text-sm min-w-max">
            <thead class="bg-gray-800 border-b border-orange-500">
              <tr>
                <th class="px-2 py-3 text-left w-20">
                  <button
                    phx-click="failures_sort"
                    phx-value-sort_by="inserted_at"
                    class="text-orange-400 hover:text-orange-300 font-bold text-xs"
                  >
                    TIME
                    <%= if @failures_sort_by == :inserted_at do %>
                      {if @failures_sort_dir == :asc, do: "↑", else: "↓"}
                    <% end %>
                  </button>
                </th>
                <th class="px-2 py-3 text-left w-20">
                  <button
                    phx-click="failures_sort"
                    phx-value-sort_by="failure_stage"
                    class="text-orange-400 hover:text-orange-300 font-bold text-xs"
                  >
                    STAGE
                    <%= if @failures_sort_by == :failure_stage do %>
                      {if @failures_sort_dir == :asc, do: "↑", else: "↓"}
                    <% end %>
                  </button>
                </th>
                <th class="px-2 py-3 text-left w-24">
                  <button
                    phx-click="failures_sort"
                    phx-value-sort_by="failure_category"
                    class="text-orange-400 hover:text-orange-300 font-bold text-xs"
                  >
                    CATEGORY
                    <%= if @failures_sort_by == :failure_category do %>
                      {if @failures_sort_dir == :asc, do: "↑", else: "↓"}
                    <% end %>
                  </button>
                </th>
                <th class="px-2 py-3 text-left max-w-xs">VIDEO</th>
                <th class="px-2 py-3 text-left max-w-sm">MESSAGE</th>
                <th class="px-2 py-3 text-left w-16">
                  <button
                    phx-click="failures_sort"
                    phx-value-sort_by="retry_count"
                    class="text-orange-400 hover:text-orange-300 font-bold text-xs"
                  >
                    RETRIES
                    <%= if @failures_sort_by == :retry_count do %>
                      {if @failures_sort_dir == :asc, do: "↑", else: "↓"}
                    <% end %>
                  </button>
                </th>
                <th class="px-2 py-3 text-left w-20">STATUS</th>
                <th class="px-2 py-3 text-left w-20">ACTIONS</th>
              </tr>
            </thead>
            <tbody>
              <%= for failure <- @failures_data.failures do %>
                <tr class="border-b border-gray-700 hover:bg-gray-800/50">
                  <td class="px-2 py-3 text-gray-300 text-xs">
                    {Calendar.strftime(failure.inserted_at, "%m/%d %H:%M")}
                  </td>
                  <td class="px-2 py-3">
                    <span class={"px-1 py-1 text-xs rounded font-bold #{stage_color(failure.failure_stage)}"}>
                      {String.upcase(to_string(failure.failure_stage)) |> String.slice(0, 6)}
                    </span>
                  </td>
                  <td class="px-2 py-3">
                    <span class={"px-1 py-1 text-xs rounded font-bold #{category_color(failure.failure_category)}"}>
                      {String.upcase(String.replace(to_string(failure.failure_category), "_", " "))
                      |> String.slice(0, 8)}
                    </span>
                  </td>
                  <td class="px-2 py-3 text-gray-300 max-w-xs">
                    <div class="truncate text-xs" title={failure.video.title}>
                      {String.slice(failure.video.title, 0, 35)}{if String.length(failure.video.title) >
                                                                      35,
                                                                    do: "..."}
                    </div>
                  </td>
                  <td class="px-2 py-3 text-gray-300 max-w-sm">
                    <div class="truncate text-xs" title={failure.failure_message}>
                      {String.slice(failure.failure_message, 0, 50)}{if String.length(
                                                                          failure.failure_message
                                                                        ) > 50, do: "..."}
                    </div>
                  </td>
                  <td class="px-2 py-3 text-center">
                    <%= if failure.retry_count > 0 do %>
                      <span class="text-yellow-400 text-xs">{failure.retry_count}</span>
                    <% else %>
                      <span class="text-gray-500 text-xs">0</span>
                    <% end %>
                  </td>
                  <td class="px-2 py-3">
                    <%= if failure.resolved do %>
                      <span class="px-1 py-1 text-xs rounded bg-green-900 text-green-400 font-bold">
                        OK
                      </span>
                    <% else %>
                      <span class="px-1 py-1 text-xs rounded bg-red-900 text-red-400 font-bold">
                        FAIL
                      </span>
                    <% end %>
                  </td>
                  <td class="px-2 py-3">
                    <button
                      phx-click="toggle_failure_details"
                      phx-value-failure_id={failure.id}
                      class="px-1 py-1 text-xs rounded bg-blue-900 text-blue-400 hover:bg-blue-800 font-bold"
                    >
                      {if @expanded_failure_id == failure.id, do: "HIDE", else: "SHOW"}
                    </button>
                  </td>
                </tr>
                
    <!-- Expandable details row -->
                <%= if @expanded_failure_id == failure.id do %>
                  <tr class="bg-gray-800/80">
                    <td colspan="8" class="px-4 py-4">
                      <div class="space-y-4">
                        <!-- Failure Details Section -->
                        <div class="bg-gray-900 border border-orange-500 rounded p-4">
                          <h4 class="text-orange-400 font-bold mb-3">FAILURE DETAILS</h4>
                          <div class="grid grid-cols-1 md:grid-cols-2 gap-4 text-sm">
                            <div>
                              <span class="text-gray-400">Failure Code:</span>
                              <span class="text-white ml-2">{failure.failure_code}</span>
                            </div>
                            <div>
                              <span class="text-gray-400">Retry Count:</span>
                              <span class="text-white ml-2">{failure.retry_count}</span>
                            </div>
                            <%= if failure.resolved_at do %>
                              <div>
                                <span class="text-gray-400">Resolved At:</span>
                                <span class="text-white ml-2">
                                  {Calendar.strftime(failure.resolved_at, "%Y-%m-%d %H:%M:%S UTC")}
                                </span>
                              </div>
                            <% end %>
                            <div class="col-span-1 md:col-span-2">
                              <span class="text-gray-400">Video Path:</span>
                              <div class="text-white mt-1 p-2 bg-black border border-gray-700 rounded text-xs font-mono break-all">
                                {failure.video.path}
                              </div>
                            </div>
                          </div>
                        </div>
                        
    <!-- Command Output Section -->
                        <%= if failure.system_context["full_output"] do %>
                          <div class="bg-gray-900 border border-orange-500 rounded p-4">
                            <h4 class="text-orange-400 font-bold mb-3">COMMAND OUTPUT LOG</h4>

                            <%= if failure.system_context["command"] do %>
                              <div class="mb-3">
                                <span class="text-gray-400">Command:</span>
                                <div class="bg-black border border-gray-700 rounded p-2 mt-1 overflow-x-auto">
                                  <code class="text-green-400 text-xs font-mono break-all whitespace-pre-wrap">
                                    {failure.system_context["command"]}
                                  </code>
                                </div>
                              </div>
                            <% end %>

                            <div>
                              <span class="text-gray-400">Output:</span>
                              <div class="bg-black border border-gray-700 rounded p-3 mt-1 max-h-96 overflow-auto">
                                <pre class="text-gray-300 text-xs font-mono whitespace-pre-wrap break-words"><%= failure.system_context["full_output"] %></pre>
                              </div>
                            </div>
                          </div>
                        <% end %>
                        
    <!-- System Context Section -->
                        <%= if failure.system_context do %>
                          <div class="bg-gray-900 border border-orange-500 rounded p-4">
                            <h4 class="text-orange-400 font-bold mb-3">SYSTEM CONTEXT</h4>
                            <div class="bg-black border border-gray-700 rounded p-3 max-h-64 overflow-y-auto">
                              <pre class="text-gray-300 text-xs font-mono"><%= Jason.encode!(failure.system_context, pretty: true) %></pre>
                            </div>
                          </div>
                        <% end %>
                      </div>
                    </td>
                  </tr>
                <% end %>
              <% end %>

              <%= if @failures_data.failures == [] do %>
                <tr>
                  <td colspan="8" class="px-4 py-8 text-center text-gray-500">
                    NO FAILURES FOUND
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
        
    <!-- Pagination -->
        <%= if @failures_data.total_pages > 1 do %>
          <div class="bg-gray-800 px-4 py-3 border-t border-orange-500">
            <div class="flex items-center justify-between">
              <div class="text-gray-400 text-sm">
                Showing {(@failures_page - 1) * @failures_per_page + 1}-{min(
                  @failures_page * @failures_per_page,
                  @failures_data.total_count
                )} of {@failures_data.total_count}
              </div>
              <div class="flex space-x-2">
                <%= if @failures_page > 1 do %>
                  <button
                    phx-click="failures_page"
                    phx-value-page="1"
                    class="px-3 py-1 bg-orange-500 text-black rounded hover:bg-orange-400"
                  >
                    ← First
                  </button>
                  <button
                    phx-click="failures_page"
                    phx-value-page={@failures_page - 1}
                    class="px-3 py-1 bg-orange-500 text-black rounded hover:bg-orange-400"
                  >
                    Prev
                  </button>
                <% end %>

                <span class="px-3 py-1 text-orange-400">
                  Page {@failures_page} of {@failures_data.total_pages}
                </span>

                <%= if @failures_page < @failures_data.total_pages do %>
                  <button
                    phx-click="failures_page"
                    phx-value-page={@failures_page + 1}
                    class="px-3 py-1 bg-orange-500 text-black rounded hover:bg-orange-400"
                  >
                    Next
                  </button>
                  <button
                    phx-click="failures_page"
                    phx-value-page={@failures_data.total_pages}
                    class="px-3 py-1 bg-orange-500 text-black rounded hover:bg-orange-400"
                  >
                    Last →
                  </button>
                <% end %>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # Helper functions for styling
  defp stage_color(:analysis), do: "bg-blue-900 text-blue-400"
  defp stage_color(:crf_search), do: "bg-purple-900 text-purple-400"
  defp stage_color(:encoding), do: "bg-yellow-900 text-yellow-400"
  defp stage_color(:post_process), do: "bg-green-900 text-green-400"
  defp stage_color(_), do: "bg-gray-900 text-gray-400"

  defp category_color(:file_access), do: "bg-red-900 text-red-400"
  defp category_color(:resource_exhaustion), do: "bg-orange-900 text-orange-400"
  defp category_color(:process_failure), do: "bg-red-900 text-red-400"
  defp category_color(:vmaf_calculation), do: "bg-purple-900 text-purple-400"
  defp category_color(:crf_optimization), do: "bg-yellow-900 text-yellow-400"
  defp category_color(_), do: "bg-gray-900 text-gray-400"

  # Get failures data for the table
  defp get_failures_data(assigns) do
    import Ecto.Query

    # Base query with video preload
    base_query =
      from f in Media.VideoFailure,
        join: v in assoc(f, :video),
        preload: [video: v]

    # Apply filters
    filtered_query =
      Enum.reduce(assigns.failures_filter || %{}, base_query, fn {key, value}, query ->
        case key do
          :stage when is_binary(value) ->
            stage_atom = String.to_existing_atom(value)
            where(query, [f], f.failure_stage == ^stage_atom)

          :category when is_binary(value) ->
            category_atom = String.to_existing_atom(value)
            where(query, [f], f.failure_category == ^category_atom)

          :video_search when is_binary(value) ->
            search_term = "%#{value}%"
            where(query, [f, v], ilike(v.title, ^search_term))

          _ ->
            query
        end
      end)

    # Get total count
    total_count = Repo.aggregate(filtered_query, :count)

    # Apply sorting and pagination
    sort_by = assigns.failures_sort_by || :inserted_at
    sort_dir = assigns.failures_sort_dir || :desc
    page = assigns.failures_page || 1
    per_page = assigns.failures_per_page || 20

    sorted_query = order_by(filtered_query, [{^sort_dir, ^sort_by}])

    offset = (page - 1) * per_page

    paginated_query =
      sorted_query
      |> limit(^per_page)
      |> offset(^offset)

    failures = Repo.all(paginated_query)
    total_pages = ceil(total_count / per_page)

    # Get statistics
    recent_count = get_recent_failures_count()
    {top_category, resolution_rate} = get_failure_stats()

    %{
      failures: failures,
      total_count: total_count,
      total_pages: total_pages,
      recent_count: recent_count,
      top_category: top_category,
      resolution_rate: resolution_rate
    }
  end

  defp get_recent_failures_count do
    import Ecto.Query
    twenty_four_hours_ago = DateTime.add(DateTime.utc_now(), -24, :hour)

    from(f in Media.VideoFailure,
      where: f.inserted_at >= ^twenty_four_hours_ago
    )
    |> Repo.aggregate(:count)
  end

  defp get_failure_stats do
    import Ecto.Query

    # Get top category
    top_category_result =
      from(f in Media.VideoFailure,
        group_by: f.failure_category,
        select: {f.failure_category, count()},
        order_by: [desc: count()],
        limit: 1
      )
      |> Repo.one()

    top_category =
      case top_category_result do
        {category, _count} -> String.upcase(String.replace(to_string(category), "_", " "))
        nil -> "N/A"
      end

    # Calculate resolution rate
    total_failures = Repo.aggregate(Media.VideoFailure, :count)

    resolved_failures =
      from(f in Media.VideoFailure, where: f.resolved == true)
      |> Repo.aggregate(:count)

    resolution_rate =
      if total_failures > 0 do
        round(resolved_failures / total_failures * 100)
      else
        0
      end

    {top_category, resolution_rate}
  end
end
