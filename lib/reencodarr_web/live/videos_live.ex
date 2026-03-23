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
  - Space saved display for encoded videos
  - Live updates via PubSub on pipeline events; periodic 30s fallback
  - Loading state for initial data fetch
  """

  use ReencodarrWeb, :live_view

  alias Reencodarr.Core.Parsers
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Media
  alias ReencodarrWeb.Live.ListPagination

  @per_page_options [25, 50, 100, 250]
  @default_per_page 50
  @update_interval 30_000
  @queueable_states [:needs_analysis, :analyzed, :crf_searched]

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
      send(self(), :load_initial_data)
    end

    {:ok,
     assign(socket,
       videos: [],
       total: 0,
       state_counts: %{},
       selected: MapSet.new(),
       expanded_bad_forms: [],
       loading: true,
       loaded_once: false,
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
      |> then(fn s ->
        if connected?(s) and s.assigns.loaded_once, do: load_data(s), else: s
      end)

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # PubSub / periodic refresh
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:load_initial_data, socket) do
    {:noreply, socket |> load_data() |> assign(:loaded_once, true)}
  end

  @impl true
  def handle_info(:periodic_update, socket) do
    Process.send_after(self(), :periodic_update, @update_interval)
    {:noreply, if(socket.assigns.loaded_once, do: load_data(socket), else: socket)}
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
    {:noreply, if(socket.assigns.loaded_once, do: load_data(socket), else: socket)}
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
       to: patch_path(socket.assigns, state: nilify_empty(state), page: 1)
     )}
  end

  @impl true
  def handle_event("filter_service", %{"service" => svc}, socket) do
    {:noreply,
     push_patch(socket,
       to: patch_path(socket.assigns, service: nilify_empty(svc), page: 1)
     )}
  end

  @impl true
  def handle_event("filter_hdr", %{"hdr" => hdr}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         patch_path(socket.assigns,
           hdr: hdr_to_param(parse_hdr_param(nilify_empty(hdr))),
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

    {:noreply, push_patch(socket, to: patch_path(socket.assigns, state: new_filter, page: 1))}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         patch_path(socket.assigns,
           search: "",
           state: nil,
           service: nil,
           hdr: nil,
           page: 1
         )
     )}
  end

  @impl true
  def handle_event("toggle_mark_bad", %{"id" => id_str}, socket) do
    case Parsers.parse_integer_exact(id_str) do
      {:ok, id} ->
        expanded = socket.assigns.expanded_bad_forms

        updated_expanded =
          if id in expanded do
            List.delete(expanded, id)
          else
            [id | expanded]
          end

        {:noreply, assign(socket, :expanded_bad_forms, updated_expanded)}

      _other ->
        {:noreply, socket}
    end
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
  def handle_event(
        "select_range",
        %{"start_id" => start_id, "end_id" => end_id, "selected" => selected},
        socket
      ) do
    with {:ok, start_id} <- Parsers.parse_integer_exact(start_id),
         {:ok, end_id} <- Parsers.parse_integer_exact(end_id) do
      ids = visible_range_ids(socket.assigns.videos, start_id, end_id)
      selected = selected == "true"

      {:noreply,
       assign(socket, :selected, apply_range_selection(socket.assigns.selected, ids, selected))}
    else
      _ -> {:noreply, socket}
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

  @impl true
  def handle_event("prioritize_selected", _params, socket) do
    ordered_ids =
      socket.assigns.videos
      |> Enum.map(& &1.id)
      |> Enum.filter(&MapSet.member?(socket.assigns.selected, &1))

    case Media.prioritize_videos(ordered_ids) do
      {:ok, 0} ->
        {:noreply,
         put_flash(socket, :error, "No selected videos were eligible for queue prioritization")}

      {:ok, count} ->
        socket = socket |> assign(selected: MapSet.new()) |> load_data()
        {:noreply, put_flash(socket, :info, "Prioritized #{count} video(s)")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to prioritize selected videos")}
    end
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
      nil ->
        {:noreply, put_flash(socket, :error, "Video not found")}

      {:error, reason} ->
        require Logger
        Logger.error("Failed to reset video #{id_str}: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Reset failed")}
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
  def handle_event("prioritize_video", %{"id" => id_str}, socket) do
    with {:ok, id} <- Parsers.parse_integer_exact(id_str),
         {:ok, count} <- Media.prioritize_video(id),
         true <- count > 0 do
      {:noreply, socket |> put_flash(:info, "Prioritized video") |> load_data()}
    else
      {:ok, 0} -> {:noreply, put_flash(socket, :error, "Video is not currently queueable")}
      false -> {:noreply, put_flash(socket, :error, "Video is not currently queueable")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to prioritize video")}
      _ -> {:noreply, put_flash(socket, :error, "Video not found")}
    end
  end

  @impl true
  def handle_event("prioritize_season_visible", %{"id" => id_str}, socket) do
    with {:ok, id} <- Parsers.parse_integer_exact(id_str),
         {:ok, season_dir} <- visible_season_directory(socket.assigns.videos, id) do
      ordered_ids =
        socket.assigns.videos
        |> Enum.filter(&(season_directory(&1.path) == season_dir))
        |> Enum.map(& &1.id)

      case Media.prioritize_videos(ordered_ids) do
        {:ok, 0} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "No visible videos in that season were eligible for prioritization"
           )}

        {:ok, count} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             "Prioritized #{count} visible #{Path.basename(season_dir)} video(s)"
           )
           |> load_data()}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Failed to prioritize visible season videos")}
      end
    else
      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Season prioritization is only available for visible season rows"
         )}
    end
  end

  @impl true
  def handle_event("delete_video", %{"id" => id_str}, socket) do
    with {:ok, id} <- Parsers.parse_integer_exact(id_str),
         {:ok, video} <- Media.fetch_video(id),
         {:ok, _} <- Media.delete_video(video) do
      {:noreply, socket |> put_flash(:info, "Video deleted") |> load_data()}
    else
      :not_found -> {:noreply, put_flash(socket, :error, "Video not found")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Delete failed")}
    end
  end

  @impl true
  def handle_event("mark_bad", %{"id" => id_str, "issue" => issue_params}, socket) do
    with {:ok, id} <- Parsers.parse_integer_exact(id_str),
         {:ok, video} <- Media.fetch_video(id),
         {:ok, _issue} <-
           Media.create_bad_file_issue(video, %{
             origin: :manual,
             issue_kind: :manual,
             classification: :manual_bad,
             manual_reason: String.trim(Map.get(issue_params, "manual_reason", "")),
             manual_note: String.trim(Map.get(issue_params, "manual_note", ""))
           }) do
      {:noreply,
       socket
       |> assign(:expanded_bad_forms, List.delete(socket.assigns.expanded_bad_forms, id))
       |> put_flash(:info, "Marked as bad")
       |> load_data()}
    else
      :not_found -> {:noreply, put_flash(socket, :error, "Video not found")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Mark bad failed")}
      _ -> {:noreply, put_flash(socket, :error, "Mark bad failed")}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp load_data(socket) do
    a = socket.assigns

    videos_task =
      Task.async(fn ->
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
      end)

    state_counts_task = Task.async(&Media.count_videos_by_state/0)

    {videos, meta} = Task.await(videos_task, :infinity)
    state_counts = Task.await(state_counts_task, :infinity)

    assign(socket,
      videos: videos,
      meta: meta,
      total: meta.total_count || 0,
      page: meta.current_page || a.page,
      per_page: meta.page_size || a.per_page,
      state_counts: state_counts,
      loading: false
    )
  end

  defp reset_video_by_id(id) do
    case Media.get_video(id) do
      nil -> :ok
      video -> Media.mark_as_needs_analysis(video)
    end
  end

  defp apply_range_selection(selected_set, ids, true) do
    Enum.reduce(ids, selected_set, &MapSet.put(&2, &1))
  end

  defp apply_range_selection(selected_set, ids, false) do
    Enum.reduce(ids, selected_set, &MapSet.delete(&2, &1))
  end

  defp visible_range_ids(videos, start_id, end_id) do
    ids = Enum.map(videos, & &1.id)

    case {Enum.find_index(ids, &(&1 == start_id)), Enum.find_index(ids, &(&1 == end_id))} do
      {nil, _} -> []
      {_, nil} -> []
      {start_idx, end_idx} when start_idx <= end_idx -> Enum.slice(ids, start_idx..end_idx)
      {start_idx, end_idx} -> Enum.slice(ids, end_idx..start_idx)
    end
  end

  defp queueable_video?(video), do: video.state in @queueable_states

  defp visible_season_directory(videos, id) do
    case Enum.find(videos, &(&1.id == id)) do
      nil ->
        :error

      video ->
        case season_directory(video.path) do
          nil -> :error
          dir -> {:ok, dir}
        end
    end
  end

  defp season_directory(path) when is_binary(path) do
    dir = Path.dirname(path)

    if Regex.match?(~r/^[Ss](?:eason\s*)?0*\d+$/i, Path.basename(dir)) do
      dir
    else
      nil
    end
  end

  defp season_directory(_path), do: nil

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

  defp max_page(%{total: total, per_page: per_page}), do: ListPagination.max_page(total, per_page)

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

  defp pagination_label(page, per_page, total),
    do: ListPagination.pagination_label(page, per_page, total)

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
                phx-click="prioritize_selected"
                class="px-4 py-2 text-sm font-medium text-white bg-emerald-600 rounded-lg hover:bg-emerald-700 transition-colors"
              >
                Prioritize {@select_count} selected
              </button>
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
                value={@state_filter || ""}
                class="bg-gray-700 border border-gray-600 text-white rounded-lg px-3 py-2 text-sm focus:ring-purple-500 focus:border-purple-500"
              >
                <option value="">All states</option>
                <%= for s <- @valid_states do %>
                  <option value={s}>{s}</option>
                <% end %>
              </select>
            </form>

            <form phx-change="filter_service">
              <select
                name="service"
                value={@service_filter || ""}
                class="bg-gray-700 border border-gray-600 text-white rounded-lg px-3 py-2 text-sm focus:ring-purple-500 focus:border-purple-500"
              >
                <option value="">All sources</option>
                <option value="sonarr">Sonarr (TV)</option>
                <option value="radarr">Radarr (Movies)</option>
              </select>
            </form>

            <form phx-change="filter_hdr">
              <select
                name="hdr"
                value={hdr_to_param(@hdr_filter) || ""}
                class="bg-gray-700 border border-gray-600 text-white rounded-lg px-3 py-2 text-sm focus:ring-purple-500 focus:border-purple-500"
              >
                <option value="">Any HDR</option>
                <option value="true">HDR only</option>
                <option value="false">SDR only</option>
              </select>
            </form>

            <form phx-change="set_per_page">
              <select
                name="per_page"
                value={@per_page}
                class="bg-gray-700 border border-gray-600 text-white rounded-lg px-3 py-2 text-sm focus:ring-purple-500 focus:border-purple-500"
              >
                <%= for n <- @per_page_options do %>
                  <option value={n}>{n} / page</option>
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
              <tbody
                id="videos-table-body"
                phx-hook="RangeSelectCheckboxes"
                class="divide-y divide-gray-600"
              >
                <%= for video <- @videos do %>
                  <tr class={"transition-colors #{if MapSet.member?(@selected, video.id), do: "bg-purple-900/20", else: "hover:bg-gray-700/50"}"}>
                    <td class="w-10 px-3 py-2 text-center">
                      <input
                        type="checkbox"
                        checked={MapSet.member?(@selected, video.id)}
                        data-range-select="video"
                        data-id={video.id}
                        class="rounded border-gray-500 bg-gray-700 text-purple-500 focus:ring-purple-500 focus:ring-offset-gray-800 cursor-pointer"
                      />
                    </td>
                    <td class="px-4 py-2 text-gray-200 max-w-0 w-full" title={video.path}>
                      <div class="font-medium text-white truncate">{Path.basename(video.path)}</div>
                      <%= if video.title do %>
                        <div class="text-xs text-gray-400 truncate">
                          {video.title}
                          <%= if video.content_year do %>
                            ({video.content_year})
                          <% end %>
                        </div>
                      <% end %>
                      <div class="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-gray-400">
                        <span class="truncate max-w-full">
                          {Path.basename(Path.dirname(video.path))}
                        </span>
                        <span>{format_resolution(video.width, video.height)}</span>
                        <span>{format_bitrate(video.bitrate)}</span>
                        <span>{service_display(video.service_type)}</span>
                        <%= if video.hdr do %>
                          <.hdr_badge hdr={video.hdr} />
                        <% end %>
                        <%= if video.original_size && video.size do %>
                          <.space_saved_badge
                            original_size={video.original_size}
                            current_size={video.size}
                          />
                        <% end %>
                      </div>
                    </td>
                    <td class="px-4 py-2 whitespace-nowrap">
                      <span class={"inline-flex items-center px-2 py-0.5 rounded text-xs font-medium #{state_badge_class(video.state)}"}>
                        {video.state}
                      </span>
                    </td>
                    <td class="px-4 py-2 text-gray-200 whitespace-nowrap">
                      {format_size(video.size)}
                    </td>
                    <td class="px-4 py-2 text-gray-300 whitespace-nowrap text-xs">
                      {format_datetime(video.updated_at)}
                    </td>
                    <td class="px-4 py-2">
                      <div class="flex flex-col gap-2">
                        <div class="flex flex-wrap gap-x-2 gap-y-1 items-center">
                          <%= if queueable_video?(video) do %>
                            <button
                              phx-click="prioritize_video"
                              phx-value-id={video.id}
                              title="Move this queued video to the top"
                              class="text-emerald-400 hover:text-emerald-300 text-xs"
                            >
                              prioritize
                            </button>
                          <% end %>
                          <%= if queueable_video?(video) and season_directory(video.path) do %>
                            <button
                              phx-click="prioritize_season_visible"
                              phx-value-id={video.id}
                              title="Move visible videos from this season to the top"
                              class="text-emerald-300 hover:text-emerald-200 text-xs"
                            >
                              prioritize season
                            </button>
                          <% end %>
                          <button
                            phx-click="force_reanalyze"
                            phx-value-id={video.id}
                            title="Force re-analyze (clears VMAFs and resets metadata)"
                            class="text-blue-400 hover:text-blue-300 text-xs"
                          >
                            scan
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
                            phx-click="toggle_mark_bad"
                            phx-value-id={video.id}
                            title="Open bad-file form"
                            class="text-amber-300 hover:text-amber-200 text-xs"
                          >
                            mark bad
                          </button>
                          <button
                            phx-click="delete_video"
                            phx-value-id={video.id}
                            data-confirm={"Delete #{Path.basename(video.path)}?"}
                            title="Remove from database"
                            class="text-red-500 hover:text-red-400 text-xs"
                          >
                            del
                          </button>
                        </div>
                        <%= if video.id in @expanded_bad_forms do %>
                          <form
                            id={"mark-bad-form-#{video.id}"}
                            phx-submit="mark_bad"
                            phx-value-id={video.id}
                            class="rounded border border-amber-700/60 bg-amber-950/30 p-2"
                          >
                            <div class="flex flex-wrap items-center gap-2">
                              <input
                                type="text"
                                name="issue[manual_reason]"
                                placeholder="Why is this bad?"
                                class="min-w-[13rem] flex-1 rounded border border-gray-600 bg-gray-700 px-2 py-1.5 text-xs text-white placeholder-gray-400"
                              />
                              <input
                                type="text"
                                name="issue[manual_note]"
                                placeholder="Optional note"
                                class="min-w-[14rem] flex-1 rounded border border-gray-600 bg-gray-700 px-2 py-1.5 text-xs text-white placeholder-gray-400"
                              />
                              <button
                                type="submit"
                                class="rounded bg-amber-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-amber-500"
                              >
                                save
                              </button>
                              <button
                                type="button"
                                phx-click="toggle_mark_bad"
                                phx-value-id={video.id}
                                class="text-xs text-gray-300 hover:text-white"
                              >
                                cancel
                              </button>
                            </div>
                          </form>
                        <% end %>
                      </div>
                    </td>
                  </tr>
                <% end %>
                <%= if @videos == [] do %>
                  <tr>
                    <td colspan="6" class="px-8 py-12 text-center text-gray-500">
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

  @state_badge_classes %{
    needs_analysis: "bg-gray-600 text-gray-200",
    analyzing: "bg-gray-700 text-gray-300",
    analyzed: "bg-blue-900 text-blue-200",
    crf_searching: "bg-yellow-900 text-yellow-200",
    crf_searched: "bg-indigo-900 text-indigo-200",
    encoding: "bg-orange-900 text-orange-200",
    encoded: "bg-green-900 text-green-200",
    failed: "bg-red-900 text-red-200"
  }

  defp state_badge_class(state),
    do: Map.get(@state_badge_classes, state, "bg-gray-600 text-gray-200")

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

  attr :original_size, :integer, required: true
  attr :current_size, :integer, required: true

  defp space_saved_badge(assigns) do
    saved = assigns.original_size - assigns.current_size
    display = format_size(saved)

    assigns = assign(assigns, display: display, saved: saved)

    ~H"""
    <span class={"font-mono #{space_saved_color(@saved)}"} title="Space saved">
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
