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
  def render(assigns), do: ReencodarrWeb.FailuresComponents.page(assigns)

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

  defp reload_failures_for_params(%{assigns: %{loaded_once: false}} = socket, _changed?) do
    if connected?(socket) do
      load_assigns = flop_list_assigns(socket.assigns)
      start_async(socket, :load_failures, fn -> fetch_failure_payload(load_assigns) end)
    else
      socket
    end
  end

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
      assign(socket, Map.put(payload, :loaded_once, true))
    else
      socket
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
end
