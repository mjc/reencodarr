defmodule ReencodarrWeb.VideosLive do
  @moduledoc "URL-driven video browsing, queue management, and worker controls."

  use ReencodarrWeb, :live_view

  alias Reencodarr.Core.Parsers
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Media
  alias Reencodarr.Media.VideoActions
  alias Reencodarr.Videos.State, as: VideosState
  alias ReencodarrWeb.Live.FlopList

  @per_page_options [25, 50, 100, 250]
  @default_per_page 50
  @update_interval 30_000

  @valid_states ~w(needs_analysis analyzing analyzed crf_searching crf_searched encoding encoded failed)
  @valid_service_types ~w(sonarr sportarr radarr)
  @valid_sort_fields ~w(path state size width bitrate updated_at priority)
  @valid_sort_dirs ~w(asc desc)

  # ---------------------------------------------------------------------------
  # Mount / params
  # ---------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        inspection_id: nil,
        inspection: nil,
        inspection_loading: false,
        videos: [],
        meta: %Flop.Meta{},
        total: 0,
        state_counts: %{},
        selected: MapSet.new(),
        expanded_bad_forms: [],
        loading: true,
        loaded_once: false,
        per_page_options: @per_page_options,
        valid_states: @valid_states,
        page: 1,
        per_page: @default_per_page,
        state_filter: nil,
        service_filter: nil,
        hdr_filter: nil,
        search: "",
        sort_by: :updated_at,
        sort_dir: :desc
      )

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())
      Process.send_after(self(), :periodic_update, @update_interval)
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
      |> then(fn socket ->
        if filters_changed?, do: assign(socket, :selected, MapSet.new()), else: socket
      end)
      |> reload_videos_for_params(filters_changed?)
      |> load_inspection(params["video"])

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # PubSub / periodic refresh
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:periodic_update, socket) do
    Process.send_after(self(), :periodic_update, @update_interval)
    {:noreply, async_refresh_videos(socket)}
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
    {:noreply, async_refresh_videos(socket)}
  end

  @impl true
  def handle_info({_event, _data}, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:load_videos, {:ok, page_state}, socket) do
    {:noreply, assign_video_payload(socket, page_state)}
  end

  @impl true
  def handle_async(:load_videos, {:exit, _reason}, socket) do
    {:noreply, socket |> assign(:loading, false) |> put_flash(:error, "Unable to load videos")}
  end

  def handle_async(:inspect_video, {:ok, {id, inspection}}, socket) do
    if id == socket.assigns.inspection_id,
      do: {:noreply, assign(socket, inspection: inspection, inspection_loading: false)},
      else: {:noreply, socket}
  end

  def handle_async(:inspect_video, {:exit, _}, socket),
    do: {:noreply, assign(socket, inspection: nil, inspection_loading: false)}

  # ---------------------------------------------------------------------------
  # Filter / sort / pagination events (push_patch keeps URL in sync)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("set_filters", params, socket) do
    search =
      params
      |> Map.get("search", socket.assigns.search)
      |> nilify_empty()
      |> then(&(&1 || ""))

    state =
      params
      |> Map.get("state", socket.assigns.state_filter)
      |> nilify_empty()
      |> coerce_in(@valid_states)

    service =
      params
      |> Map.get("service", socket.assigns.service_filter)
      |> nilify_empty()
      |> coerce_in(@valid_service_types)

    hdr =
      params
      |> Map.get("hdr", hdr_to_param(socket.assigns.hdr_filter))
      |> nilify_empty()
      |> parse_hdr_param()
      |> hdr_to_param()

    {:noreply,
     push_patch(socket,
       to:
         patch_path(socket.assigns,
           search: search,
           state: state,
           service: service,
           hdr: hdr,
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
    col_atom = coerce_atom_in(col, @valid_sort_fields, socket.assigns.sort_by)

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
    reset_count = Media.reset_videos_to_needs_analysis(ids)
    socket = socket |> assign(selected: MapSet.new()) |> load_data()

    {:noreply, put_flash(socket, :info, "Reset #{reset_count} video(s) to needs_analysis")}
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
        socket = socket |> assign(selected: MapSet.new())
        {:noreply, put_flash(socket, :info, "Prioritized #{count} video(s)")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to prioritize selected videos")}
    end
  end

  # ---------------------------------------------------------------------------
  # Per-row actions
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event(event, %{"id" => raw_id}, socket)
      when event in ["reset_video", "force_reanalyze", "delete_video"] do
    action =
      %{"reset_video" => :reset, "force_reanalyze" => :reanalyze, "delete_video" => :delete}[
        event
      ]

    message =
      %{
        reset: "Reset to needs_analysis",
        reanalyze: "Queued for re-analysis",
        delete: "Video deleted"
      }[action]

    with {:ok, id} <- Parsers.parse_integer_exact(raw_id),
         {:ok, _} <- VideoActions.mutate(id, action) do
      {:noreply,
       socket
       |> put_flash(:info, message)
       |> load_data()
       |> push_patch(to: patch_path(socket.assigns, []))}
    else
      {:error, :active} ->
        {:noreply, put_flash(socket, :error, "Stop the active job before changing this video")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Video not found")}

      _ ->
        {:noreply, put_flash(socket, :error, "Unable to change video")}
    end
  end

  def handle_event("inspect_video", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: patch_path(socket.assigns, video: id))}
  end

  def handle_event("control_video", %{"id" => id, "action" => action}, socket)
      when action in ["pause", "resume", "stop"] do
    with {:ok, id} <- Parsers.parse_integer_exact(id),
         :ok <- VideoActions.control(id, String.to_existing_atom(action)) do
      {:noreply,
       socket
       |> put_flash(:info, "Worker #{action} requested")
       |> load_data()
       |> refresh_inspection()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Worker is unavailable; no command was sent")}
    end
  end

  @impl true
  def handle_event("prioritize_video", %{"id" => id_str}, socket) do
    with {:ok, id} <- Parsers.parse_integer_exact(id_str),
         {:ok, count} <- Media.prioritize_video(id),
         true <- count > 0 do
      {:noreply, socket |> put_flash(:info, "Prioritized video")}
    else
      false -> {:noreply, put_flash(socket, :error, "Video is not currently queueable")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to prioritize video")}
    end
  end

  @impl true
  def handle_event("fail_video", %{"id" => id_str}, socket) do
    case Parsers.parse_integer_exact(id_str) do
      {:ok, id} ->
        case fail_video_by_id(id) do
          :ok ->
            {:noreply, socket |> put_flash(:info, "Worker stop requested") |> load_data()}

          {:ok, :removed} ->
            {:noreply, socket |> put_flash(:info, "Removed from queue") |> load_data()}

          {:error, :active_mismatch} ->
            {:noreply, socket |> put_flash(:error, "That video is not the active job")}

          _ ->
            {:noreply, socket |> put_flash(:error, "Unable to stop job")}
        end

      _ ->
        {:noreply, socket |> put_flash(:error, "Unable to stop job")}
    end
  end

  @impl true
  def handle_event("prioritize_season_visible", %{"id" => id_str}, socket) do
    with {:ok, id} <- Parsers.parse_integer_exact(id_str),
         {:ok, season_dir} <- visible_season_directory(socket.assigns.videos, id) do
      ordered_ids =
        season_dir
        |> season_videos()
        |> Enum.sort_by(& &1.path)
        |> Enum.map(& &1.id)

      case Media.prioritize_videos(ordered_ids) do
        {:ok, 0} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "No videos in that season were eligible for prioritization"
           )}

        {:ok, count} ->
          {:noreply,
           put_flash(
             socket,
             :info,
             "Prioritized #{count} #{Path.basename(season_dir)} video(s)"
           )}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Failed to prioritize season videos")}
      end
    else
      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Season prioritization is only available for season rows"
         )}
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
       |> put_flash(:info, "Marked as bad")}
    else
      :not_found -> {:noreply, put_flash(socket, :error, "Video not found")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Mark bad failed")}
      _ -> {:noreply, put_flash(socket, :error, "Mark bad failed")}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp refresh_inspection(%{assigns: %{inspection_id: nil}} = socket), do: socket

  defp refresh_inspection(socket) do
    id = socket.assigns.inspection_id
    socket |> assign(:inspection_id, nil) |> load_inspection(to_string(id))
  end

  defp load_inspection(socket, raw_id) do
    id = parse_inspection_id(raw_id)

    cond do
      id == socket.assigns.inspection_id ->
        socket

      is_nil(id) ->
        assign(socket, inspection_id: nil, inspection: nil, inspection_loading: false)

      true ->
        start_inspection(socket, id)
    end
  end

  defp parse_inspection_id(raw_id) do
    case Parsers.parse_integer_exact(raw_id || "") do
      {:ok, id} -> id
      _ -> nil
    end
  end

  defp start_inspection(socket, id) do
    socket = assign(socket, inspection_id: id, inspection: nil, inspection_loading: true)

    if connected?(socket),
      do: start_async(socket, :inspect_video, fn -> {id, fetch_inspection(id)} end),
      else: socket
  end

  defp fetch_inspection(id) do
    case Media.fetch_video(id) do
      {:ok, video} -> %{video: video, vmafs: Media.get_vmafs_for_video(id)}
      _ -> nil
    end
  end

  defp load_data(socket, opts \\ []) do
    page_state = fetch_video_payload(socket.assigns, opts)

    assign_video_payload(socket, page_state)
  end

  defp reload_videos_for_params(%{assigns: %{loaded_once: false}} = socket, _changed?) do
    if connected?(socket) do
      load_assigns = video_load_assigns(socket.assigns)
      start_async(socket, :load_videos, fn -> fetch_video_payload(load_assigns, []) end)
    else
      socket
    end
  end

  defp reload_videos_for_params(socket, false), do: socket

  defp reload_videos_for_params(socket, _changed?) do
    load_data(socket, include_state_counts: false)
  end

  defp async_refresh_videos(%{assigns: %{loaded_once: false}} = socket), do: socket

  defp async_refresh_videos(socket) do
    if connected?(socket) do
      load_assigns = video_load_assigns(socket.assigns)

      socket
      |> assign(:loading, true)
      |> start_async(:load_videos, fn ->
        fetch_video_payload(load_assigns, include_state_counts: false)
      end)
    else
      assign(socket, :loading, false)
    end
  end

  defp fetch_video_payload(assigns, opts) do
    VideosState.load(
      video_load_assigns(assigns),
      opts
    )
    |> Map.put(:request, video_request_assigns(assigns))
  end

  defp video_load_assigns(assigns) do
    Map.take(assigns, [
      :state_counts,
      :page,
      :per_page,
      :state_filter,
      :service_filter,
      :hdr_filter,
      :search,
      :sort_by,
      :sort_dir
    ])
  end

  defp video_request_assigns(assigns) do
    Map.take(assigns, [
      :page,
      :per_page,
      :state_filter,
      :service_filter,
      :hdr_filter,
      :search,
      :sort_by,
      :sort_dir
    ])
  end

  defp assign_video_payload(socket, %{request: request} = page_state) do
    if video_request_assigns(socket.assigns) == request do
      page_state =
        page_state
        |> Map.delete(:request)
        |> Map.put(:loading, false)
        |> Map.put(:loaded_once, true)

      visible = MapSet.new(page_state.videos, & &1.id)

      socket
      |> assign(page_state)
      |> assign(:selected, MapSet.intersection(socket.assigns.selected, visible))
    else
      socket
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

  defp fail_video_by_id(id) do
    with {:ok, video} <- Media.fetch_video(id) do
      fail_video(video)
    end
  end

  defp fail_video(%{state: :analyzed} = video) do
    with {:ok, _} <- Media.fail_video_by_operator(video, :crf_search), do: {:ok, :removed}
  end

  defp fail_video(%{state: :crf_searched} = video) do
    with {:ok, _} <- Media.fail_video_by_operator(video, :encoding), do: {:ok, :removed}
  end

  defp fail_video(%{state: state, id: id}) when state in [:crf_searching, :encoding],
    do: VideoActions.control(id, :stop)

  defp fail_video(_video), do: {:error, :not_fail_actionable}

  defp visible_season_directory(videos, id) do
    case Enum.find(videos, &(&1.id == id)) do
      nil ->
        :error

      video ->
        case ReencodarrWeb.VideoPresentation.season_directory(video.path) do
          nil -> :error
          dir -> {:ok, dir}
        end
    end
  end

  defp season_videos(season_dir) do
    Media.find_videos_by_path_wildcard("#{escape_like(season_dir)}/%")
  end

  defp escape_like(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp escape_like(value), do: value

  defp parse_params(params) do
    Map.merge(
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
        search: params |> Map.get("search", "") |> nilify_empty() |> then(&(&1 || ""))
      },
      FlopList.pagination_assigns(params, @default_per_page, @per_page_options)
    )
  end

  # Build the /videos path with all current assigns merged with overrides.
  # Omits nil/empty values to keep URLs clean.
  defp videos_url_query(assigns) do
    %{
      "sort_by" => to_string(assigns.sort_by),
      "sort_dir" => to_string(assigns.sort_dir),
      "per_page" => assigns.per_page,
      "search" => assigns.search,
      "state" => assigns.state_filter,
      "service" => assigns.service_filter,
      "hdr" => hdr_to_param(assigns.hdr_filter)
    }
    |> drop_default_query_values()
  end

  defp patch_path(assigns, overrides) do
    overrides_map = Enum.into(overrides, %{}, fn {k, v} -> {to_string(k), v} end)

    query =
      assigns
      |> videos_url_query()
      |> Map.merge(overrides_map)
      |> drop_default_query_values()

    page =
      overrides
      |> Keyword.get(:page, assigns.page)
      |> Parsers.parse_int(assigns.page)
      |> max(1)

    FlopList.patch_with_page("/videos", query, page)
  end

  defp drop_default_query_values(query) do
    Map.reject(query, fn
      {"sort_by", value} -> value in [:updated_at, "updated_at"]
      {"sort_dir", value} -> value in [:desc, "desc"]
      {"per_page", value} -> value in [@default_per_page, to_string(@default_per_page)]
      {_key, value} -> value in [nil, ""]
    end)
  end

  defp max_page(%{total: total, per_page: per_page}), do: FlopList.total_pages(total, per_page)

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

  defp filters_changed?(assigns, filters) do
    Enum.any?(Map.keys(filters), fn key -> Map.get(assigns, key) != Map.get(filters, key) end)
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns),
    do:
      ReencodarrWeb.VideosComponents.page(
        assign(assigns,
          url_query: videos_url_query(assigns),
          close_inspection: patch_path(assigns, [])
        )
      )
end
