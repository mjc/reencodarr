defmodule ReencodarrWeb.VideosLive do
  @moduledoc """
  LiveView for browsing, filtering, and managing videos.

  ## Features
  - URL-driven state: all filters/sort/page are query params (bookmarkable, shareable)
  - Sortable columns with click-to-toggle direction indicators
  - Filter by state, service type (sonarr/radarr), HDR presence
  - Full-text search with debounce
  - Per-page selector (25/50/100/250)
  - State stats bar: clickable count badges per pipeline state
  - Bulk selection and bulk reset to needs_analysis
  - Per-row actions: reset, force re-analyze, delete
  - VMAF score column for crf_searched/encoded videos
  - Live updates via PubSub on pipeline events; periodic 30s fallback
  - Loading state for initial data fetch
  """

  use ReencodarrWeb, :live_view

  alias Reencodarr.Core.Parsers
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Media

  @per_page_options [25, 50, 100, 250]
  @default_per_page 50
  @update_interval 30_000

  @valid_states ~w(needs_analysis analyzed crf_searching crf_searched encoding encoded failed)
  @valid_service_types ~w(sonarr radarr)
  @valid_sort_fields ~w(path state size width bitrate updated_at)
  @valid_sort_dirs ~w(asc desc)

  # ---------------------------------------------------------------------------
  # Mount / params
  # ---------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())
      Process.send_after(self(), :periodic_update, @update_interval)
    end

    {:ok,
     assign(socket,
       videos: [],
       total: 0,
       state_counts: %{},
       selected: MapSet.new(),
       loading: true,
       per_page_options: @per_page_options,
       valid_states: @valid_states
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = parse_params(params)

    socket =
      socket
      |> assign(filters)
      |> then(fn s -> if connected?(s), do: load_data(s), else: s end)

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # PubSub / periodic refresh
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:periodic_update, socket) do
    Process.send_after(self(), :periodic_update, @update_interval)
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({event, _data}, socket)
      when event in [
             :encoding_completed,
             :encoding_started,
             :crf_search_completed,
             :crf_search_started,
             :analyzer_progress
           ] do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({_event, _data}, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Filter / sort / pagination events (push_patch keeps URL in sync)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("search", %{"search" => q}, socket) do
    {:noreply, push_patch(socket, to: patch_path(socket.assigns, search: q, page: 1))}
  end

  @impl true
  def handle_event("filter_state", %{"state" => state}, socket) do
    {:noreply,
     push_patch(socket,
       to: patch_path(socket.assigns, state_filter: nilify_empty(state), page: 1)
     )}
  end

  @impl true
  def handle_event("filter_service", %{"service" => svc}, socket) do
    {:noreply,
     push_patch(socket,
       to: patch_path(socket.assigns, service_filter: nilify_empty(svc), page: 1)
     )}
  end

  @impl true
  def handle_event("filter_hdr", %{"hdr" => hdr}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         patch_path(socket.assigns,
           hdr_filter: parse_hdr_param(nilify_empty(hdr)),
           page: 1
         )
     )}
  end

  @impl true
  def handle_event("set_per_page", %{"per_page" => n}, socket) do
    n = Parsers.parse_int(n, @default_per_page)
    n = if n in @per_page_options, do: n, else: @default_per_page
    {:noreply, push_patch(socket, to: patch_path(socket.assigns, per_page: n, page: 1))}
  end

  @impl true
  def handle_event("sort", %{"col" => col}, socket) do
    col_atom = String.to_existing_atom(col)

    {sort_by, sort_dir} =
      if socket.assigns.sort_by == col_atom,
        do: {col_atom, toggle_dir(socket.assigns.sort_dir)},
        else: {col_atom, :asc}

    {:noreply,
     push_patch(socket,
       to: patch_path(socket.assigns, sort_by: sort_by, sort_dir: sort_dir, page: 1)
     )}
  rescue
    ArgumentError -> {:noreply, socket}
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
    if socket.assigns.page < max_page(socket.assigns) do
      {:noreply,
       push_patch(socket, to: patch_path(socket.assigns, page: socket.assigns.page + 1))}
    else
      {:noreply, socket}
    end
  end

  # Clicking a state badge in the stats bar toggles that filter
  @impl true
  def handle_event("quick_filter_state", %{"state" => state}, socket) do
    new_filter = if socket.assigns.state_filter == state, do: nil, else: state

    {:noreply,
     push_patch(socket, to: patch_path(socket.assigns, state_filter: new_filter, page: 1))}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         patch_path(socket.assigns,
           search: "",
           state_filter: nil,
           service_filter: nil,
           hdr_filter: nil,
           page: 1
         )
     )}
  end

  # ---------------------------------------------------------------------------
  # Bulk selection
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("toggle_select", %{"id" => id_str}, socket) do
    case Parsers.parse_integer_exact(id_str) do
      {:ok, id} ->
        {:noreply, assign(socket, selected: toggle_member(socket.assigns.selected, id))}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_all", _params, socket) do
    ids = MapSet.new(socket.assigns.videos, & &1.id)
    {:noreply, assign(socket, selected: ids)}
  end

  @impl true
  def handle_event("deselect_all", _params, socket) do
    {:noreply, assign(socket, selected: MapSet.new())}
  end

  @impl true
  def handle_event("reset_selected", _params, socket) do
    ids = MapSet.to_list(socket.assigns.selected)
    Enum.each(ids, &reset_video_by_id/1)

    socket = socket |> assign(selected: MapSet.new()) |> load_data()
    {:noreply, put_flash(socket, :info, "Reset #{length(ids)} video(s) to needs_analysis")}
  end

  # ---------------------------------------------------------------------------
  # Per-row actions
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("reset_video", %{"id" => id_str}, socket) do
    with {:ok, id} <- Parsers.parse_integer_exact(id_str),
         video when not is_nil(video) <- Media.get_video(id),
         {:ok, _} <- Media.mark_as_needs_analysis(video) do
      {:noreply, socket |> put_flash(:info, "Reset to needs_analysis") |> load_data()}
    else
      nil -> {:noreply, put_flash(socket, :error, "Video not found")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Reset failed")}
    end
  end

  @impl true
  def handle_event("force_reanalyze", %{"id" => id_str}, socket) do
    case Parsers.parse_integer_exact(id_str) do
      {:ok, id} ->
        Media.force_reanalyze_video(id)
        {:noreply, socket |> put_flash(:info, "Queued for re-analysis") |> load_data()}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("delete_video", %{"id" => id_str}, socket) do
    with {:ok, id} <- Parsers.parse_integer_exact(id_str),
         video when not is_nil(video) <- Media.get_video(id),
         {:ok, _} <- Media.delete_video(video) do
      {:noreply, socket |> put_flash(:info, "Video deleted") |> load_data()}
    else
      nil -> {:noreply, put_flash(socket, :error, "Video not found")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Delete failed")}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp load_data(socket) do
    a = socket.assigns

    {videos, total} =
      Media.list_videos_paginated(
        page: a.page,
        per_page: a.per_page,
        state: a.state_filter,
        service_type: a.service_filter,
        hdr: a.hdr_filter,
        search: a.search,
        sort_by: a.sort_by,
        sort_dir: a.sort_dir
      )

    state_counts = Media.count_videos_by_state()
    assign(socket, videos: videos, total: total, state_counts: state_counts, loading: false)
  end

  defp reset_video_by_id(id) do
    case Media.get_video(id) do
      nil -> :ok
      video -> Media.mark_as_needs_analysis(video)
    end
  end

  defp parse_params(params) do
    %{
      sort_by:
        params
        |> Map.get("sort_by", "updated_at")
        |> coerce_atom_in(@valid_sort_fields, :updated_at),
      sort_dir:
        params
        |> Map.get("sort_dir", "desc")
        |> coerce_atom_in(@valid_sort_dirs, :desc),
      state_filter: params |> Map.get("state") |> nilify_empty() |> coerce_in(@valid_states),
      service_filter:
        params |> Map.get("service") |> nilify_empty() |> coerce_in(@valid_service_types),
      hdr_filter: params |> Map.get("hdr") |> nilify_empty() |> parse_hdr_param(),
      search: params |> Map.get("search", "") |> nilify_empty() |> then(&(&1 || "")),
      page: params |> Map.get("page", "1") |> Parsers.parse_int(1) |> max(1),
      per_page:
        params
        |> Map.get("per_page", "#{@default_per_page}")
        |> Parsers.parse_int(@default_per_page)
        |> then(&if(&1 in @per_page_options, do: &1, else: @default_per_page))
    }
  end

  # Build the /videos path with all current assigns merged with overrides.
  # Omits nil/empty values to keep URLs clean.
  defp patch_path(assigns, overrides) do
    overrides_map = Enum.into(overrides, %{}, fn {k, v} -> {to_string(k), v} end)

    query =
      %{
        "sort_by" => to_string(assigns.sort_by),
        "sort_dir" => to_string(assigns.sort_dir),
        "page" => assigns.page,
        "per_page" => assigns.per_page,
        "search" => assigns.search,
        "state" => assigns.state_filter,
        "service" => assigns.service_filter,
        "hdr" => hdr_to_param(assigns.hdr_filter)
      }
      |> Map.merge(overrides_map)
      |> Enum.reject(fn {_, v} -> is_nil(v) || v == "" end)
      |> Enum.map(fn {k, v} -> {k, to_string(v)} end)
      |> URI.encode_query()

    "/videos?#{query}"
  end

  defp max_page(%{total: total, per_page: per_page}), do: max(ceil(total / per_page), 1)

  defp toggle_dir(:asc), do: :desc
  defp toggle_dir(:desc), do: :asc

  defp toggle_member(set, id) do
    if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
  end

  defp nilify_empty(nil), do: nil
  defp nilify_empty(""), do: nil
  defp nilify_empty(v), do: v

  defp coerce_in(nil, _valid), do: nil
  defp coerce_in(v, valid), do: if(v in valid, do: v, else: nil)

  defp coerce_atom_in(v, valid, default) do
    if v in valid, do: String.to_existing_atom(v), else: default
  end

  defp parse_hdr_param("true"), do: true
  defp parse_hdr_param("false"), do: false
  defp parse_hdr_param(_), do: nil

  defp hdr_to_param(true), do: "true"
  defp hdr_to_param(false), do: "false"
  defp hdr_to_param(_), do: nil

  defp filters_active?(assigns) do
    assigns.search != "" or not is_nil(assigns.state_filter) or
      not is_nil(assigns.service_filter) or not is_nil(assigns.hdr_filter)
  end

  defp pagination_label(page, per_page, total) when total > 0 do
    first = (page - 1) * per_page + 1
    last = min(page * per_page, total)
    "#{first}-#{last} of #{total}"
  end

  defp pagination_label(_, _, _), do: "0 results"

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        max_page: max_page(assigns),
        filters_active: filters_active?(assigns),
        select_count: MapSet.size(assigns.selected)
      )

    ~H"""
    <div class="min-h-screen bg-gray-900 p-6">
      <div class="max-w-full mx-auto space-y-4">
        <!-- Header -->
        <div class="flex justify-between items-start flex-wrap gap-3">
          <div>
            <h1 class="text-3xl font-bold text-white">Videos</h1>
            <p class="text-gray-400">{@total} total</p>
          </div>
          <div class="flex gap-2 flex-wrap">
            <%= if @select_count > 0 do %>
              <button
                phx-click="reset_selected"
                class="px-4 py-2 text-sm font-medium text-white bg-purple-600 rounded-lg hover:bg-purple-700 transition-colors"
              >
                Reset {@select_count} selected
              </button>
              <button
                phx-click="deselect_all"
                class="px-4 py-2 text-sm font-medium text-gray-300 bg-gray-700 rounded-lg hover:bg-gray-600 transition-colors"
              >
                Clear selection
              </button>
            <% end %>
            <%= if @filters_active do %>
              <button
                phx-click="clear_filters"
                class="px-4 py-2 text-sm font-medium text-gray-300 bg-gray-700 rounded-lg hover:bg-gray-600 transition-colors"
              >
                Clear filters
              </button>
            <% end %>
          </div>
        </div>
        
    <!-- State stats bar -->
        <div class="flex flex-wrap gap-2">
          <%= for state <- @valid_states do %>
            <% count = Map.get(@state_counts, String.to_existing_atom(state), 0) %>
            <button
              phx-click="quick_filter_state"
              phx-value-state={state}
              class={"flex items-center gap-1.5 px-3 py-1.5 rounded-full text-xs font-medium transition-all #{stats_badge_class(state, @state_filter)}"}
            >
              <span>{state}</span>
              <span class="bg-black/20 rounded-full px-1.5 py-0.5 font-mono">{count}</span>
            </button>
          <% end %>
        </div>
        
    <!-- Toolbar -->
        <div class="bg-gray-800 rounded-lg border border-gray-700 p-3">
          <div class="flex flex-wrap gap-3 items-center">
            <form phx-change="search" class="flex-1 min-w-[180px]">
              <input
                type="text"
                name="search"
                value={@search}
                placeholder="Search by path..."
                phx-debounce="300"
                class="w-full bg-gray-700 border border-gray-600 text-white rounded-lg px-3 py-2 text-sm focus:ring-purple-500 focus:border-purple-500 placeholder-gray-400"
              />
            </form>

            <form phx-change="filter_state">
              <select
                name="state"
                class="bg-gray-700 border border-gray-600 text-white rounded-lg px-3 py-2 text-sm focus:ring-purple-500 focus:border-purple-500"
              >
                <option value="" selected={is_nil(@state_filter)}>All states</option>
                <%= for s <- @valid_states do %>
                  <option value={s} selected={@state_filter == s}>{s}</option>
                <% end %>
              </select>
            </form>

            <form phx-change="filter_service">
              <select
                name="service"
                class="bg-gray-700 border border-gray-600 text-white rounded-lg px-3 py-2 text-sm focus:ring-purple-500 focus:border-purple-500"
              >
                <option value="" selected={is_nil(@service_filter)}>All sources</option>
                <option value="sonarr" selected={@service_filter == "sonarr"}>Sonarr (TV)</option>
                <option value="radarr" selected={@service_filter == "radarr"}>Radarr (Movies)</option>
              </select>
            </form>

            <form phx-change="filter_hdr">
              <select
                name="hdr"
                class="bg-gray-700 border border-gray-600 text-white rounded-lg px-3 py-2 text-sm focus:ring-purple-500 focus:border-purple-500"
              >
                <option value="" selected={is_nil(@hdr_filter)}>Any HDR</option>
                <option value="true" selected={@hdr_filter == true}>HDR only</option>
                <option value="false" selected={@hdr_filter == false}>SDR only</option>
              </select>
            </form>

            <form phx-change="set_per_page">
              <select
                name="per_page"
                class="bg-gray-700 border border-gray-600 text-white rounded-lg px-3 py-2 text-sm focus:ring-purple-500 focus:border-purple-500"
              >
                <%= for n <- @per_page_options do %>
                  <option value={n} selected={@per_page == n}>{n} / page</option>
                <% end %>
              </select>
            </form>
          </div>
        </div>
        
    <!-- Loading / table -->
        <%= if @loading do %>
          <div class="bg-gray-800 rounded-lg border border-gray-700 p-16 text-center">
            <div class="animate-spin rounded-full h-10 w-10 border-b-2 border-purple-500 mx-auto mb-3">
            </div>
            <p class="text-gray-400">Loading...</p>
          </div>
        <% else %>
          <div class="bg-gray-800 rounded-lg border border-gray-700 overflow-x-auto">
            <table class="min-w-full divide-y divide-gray-700 text-sm">
              <thead class="bg-gray-700/80">
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
                        class="rounded border-gray-500 bg-gray-700 text-purple-500 focus:ring-purple-500 focus:ring-offset-gray-800 cursor-pointer"
                      />
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
                    col={:width}
                    label="Resolution"
                    sort_by={@sort_by}
                    sort_dir={@sort_dir}
                  />
                  <.col_header
                    col={:bitrate}
                    label="Bitrate"
                    sort_by={@sort_by}
                    sort_dir={@sort_dir}
                  />
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-300 uppercase tracking-wider whitespace-nowrap">
                    VMAF
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-300 uppercase tracking-wider whitespace-nowrap">
                    HDR
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-300 uppercase tracking-wider whitespace-nowrap">
                    Source
                  </th>
                  <.col_header
                    col={:updated_at}
                    label="Updated"
                    sort_by={@sort_by}
                    sort_dir={@sort_dir}
                  />
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-300 uppercase tracking-wider whitespace-nowrap">
                    Actions
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-600">
                <%= for video <- @videos do %>
                  <tr class={"transition-colors #{if MapSet.member?(@selected, video.id), do: "bg-purple-900/20", else: "hover:bg-gray-700/50"}"}>
                    <td class="w-10 px-3 py-2 text-center">
                      <input
                        type="checkbox"
                        checked={MapSet.member?(@selected, video.id)}
                        phx-click="toggle_select"
                        phx-value-id={video.id}
                        class="rounded border-gray-500 bg-gray-700 text-purple-500 focus:ring-purple-500 focus:ring-offset-gray-800 cursor-pointer"
                      />
                    </td>
                    <td class="px-4 py-2 text-gray-200 max-w-0 w-full" title={video.path}>
                      <%= if video.title do %>
                        <div class="font-medium text-white truncate">{video.title}</div>
                        <div class="text-xs text-gray-400 truncate">
                          {Path.basename(video.path)}
                          <%= if video.content_year do %>
                            ({video.content_year})
                          <% end %>
                        </div>
                      <% else %>
                        <div class="truncate">{Path.basename(video.path)}</div>
                      <% end %>
                    </td>
                    <td class="px-4 py-2 whitespace-nowrap">
                      <span class={"inline-flex items-center px-2 py-0.5 rounded text-xs font-medium #{state_badge_class(video.state)}"}>
                        {video.state}
                      </span>
                    </td>
                    <td class="px-4 py-2 text-gray-200 whitespace-nowrap">
                      {format_size(video.size)}
                    </td>
                    <td class="px-4 py-2 text-gray-200 whitespace-nowrap">
                      {format_resolution(video.width, video.height)}
                    </td>
                    <td class="px-4 py-2 text-gray-200 whitespace-nowrap">
                      {format_bitrate(video.bitrate)}
                    </td>
                    <td class="px-4 py-2 whitespace-nowrap">
                      <.vmaf_badge vmaf={video.chosen_vmaf} />
                    </td>
                    <td class="px-4 py-2 whitespace-nowrap">
                      <.hdr_badge hdr={video.hdr} />
                    </td>
                    <td class="px-4 py-2 whitespace-nowrap text-gray-300">
                      {service_display(video.service_type)}
                    </td>
                    <td class="px-4 py-2 text-gray-300 whitespace-nowrap text-xs">
                      {format_datetime(video.updated_at)}
                    </td>
                    <td class="px-4 py-2">
                      <div class="flex gap-2 items-center">
                        <button
                          phx-click="force_reanalyze"
                          phx-value-id={video.id}
                          title="Force re-analyze (clears VMAFs and resets metadata)"
                          class="text-blue-400 hover:text-blue-300 text-xs"
                        >
                          re-analyze
                        </button>
                        <%= if video.state in [:failed, :encoded, :crf_searched, :analyzed] do %>
                          <button
                            phx-click="reset_video"
                            phx-value-id={video.id}
                            title="Reset to needs_analysis"
                            class="text-purple-400 hover:text-purple-300 text-xs"
                          >
                            reset
                          </button>
                        <% end %>
                        <button
                          phx-click="delete_video"
                          phx-value-id={video.id}
                          data-confirm={"Delete #{Path.basename(video.path)}?"}
                          title="Remove from database"
                          class="text-red-500 hover:text-red-400 text-xs"
                        >
                          delete
                        </button>
                      </div>
                    </td>
                  </tr>
                <% end %>
                <%= if @videos == [] do %>
                  <tr>
                    <td colspan="11" class="px-8 py-12 text-center text-gray-500">
                      No videos match the current filters.
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
          
    <!-- Pagination -->
          <div class="flex justify-between items-center text-sm text-gray-400">
            <span>{pagination_label(@page, @per_page, @total)}</span>
            <div class="flex gap-2">
              <button
                phx-click="prev_page"
                disabled={@page <= 1}
                class="px-3 py-1 bg-gray-700 rounded text-gray-300 hover:bg-gray-600 disabled:opacity-40 disabled:cursor-not-allowed"
              >
                Previous
              </button>
              <span class="px-3 py-1">{@page} / {@max_page}</span>
              <button
                phx-click="next_page"
                disabled={@page >= @max_page}
                class="px-3 py-1 bg-gray-700 rounded text-gray-300 hover:bg-gray-600 disabled:opacity-40 disabled:cursor-not-allowed"
              >
                Next
              </button>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Components
  # ---------------------------------------------------------------------------

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
    <th class={"px-4 py-3 text-left text-xs font-medium text-gray-300 uppercase tracking-wider whitespace-nowrap #{@class}"}>
      <button
        phx-click="sort"
        phx-value-col={@col}
        class={"flex items-center gap-1 hover:text-white transition-colors #{if @is_sorted, do: "text-purple-400", else: ""}"}
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

  defp sort_icon(sort_by, col, dir) when sort_by == col, do: if(dir == :asc, do: "^", else: "v")
  defp sort_icon(_, _, _), do: "~"

  defp state_badge_class(state) do
    case state do
      :needs_analysis -> "bg-gray-600 text-gray-200"
      :analyzed -> "bg-blue-900 text-blue-200"
      :crf_searching -> "bg-yellow-900 text-yellow-200"
      :crf_searched -> "bg-indigo-900 text-indigo-200"
      :encoding -> "bg-orange-900 text-orange-200"
      :encoded -> "bg-green-900 text-green-200"
      :failed -> "bg-red-900 text-red-200"
      _ -> "bg-gray-600 text-gray-200"
    end
  end

  defp stats_badge_class(state, active_filter) do
    base = state_badge_class(String.to_existing_atom(state))

    if active_filter == state,
      do: "#{base} ring-2 ring-white/60",
      else: "#{base} opacity-80 hover:opacity-100"
  end

  defp service_display(nil), do: "-"
  defp service_display(:sonarr), do: "TV"
  defp service_display(:radarr), do: "Movie"
  defp service_display(_), do: "-"

  defp hdr_display(nil), do: "-"
  defp hdr_display(""), do: "-"
  defp hdr_display(hdr), do: hdr

  attr :hdr, :any, required: true

  defp hdr_badge(%{hdr: v} = assigns) when v in [nil, ""],
    do: ~H(<span class="text-gray-500">—</span>)

  defp hdr_badge(assigns) do
    ~H"""
    <span class="inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium bg-amber-900/60 text-amber-300 border border-amber-700/50">
      {@hdr}
    </span>
    """
  end

  defp vmaf_display(nil), do: "-"

  defp vmaf_display(vmaf) do
    score = Float.round(vmaf.score * 1.0, 1)
    "#{score}"
  end

  attr :vmaf, :any, required: true

  defp vmaf_badge(%{vmaf: nil} = assigns),
    do: ~H(<span class="text-gray-500">—</span>)

  defp vmaf_badge(assigns) do
    assigns = assign(assigns, :display, Float.round(assigns.vmaf.score * 1.0, 1))

    ~H"""
    <span class={"font-mono #{vmaf_color(@display)}"}>{@display}</span>
    """
  end

  defp vmaf_color(s) when s >= 95, do: "text-green-300"
  defp vmaf_color(s) when s >= 90, do: "text-yellow-300"
  defp vmaf_color(_), do: "text-red-400"

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
