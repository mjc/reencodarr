defmodule ReencodarrWeb.VideosLive do
  @moduledoc """
  LiveView for browsing and filtering videos in the database.
  """

  use ReencodarrWeb, :live_view

  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Media

  @per_page 50
  @update_interval 30_000
  @valid_states ~w(needs_analysis analyzed crf_searching crf_searched encoding encoded failed)
  @sortable_columns ~w(path state size width updated_at)a

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())
      Process.send_after(self(), :periodic_update, @update_interval)
    end

    socket =
      socket
      |> assign(
        page: 1,
        state_filter: nil,
        search: "",
        sort_by: :updated_at,
        sort_dir: :desc,
        videos: [],
        total: 0
      )
      |> load_videos()

    {:ok, socket}
  end

  @impl true
  def handle_info(:periodic_update, socket) do
    Process.send_after(self(), :periodic_update, @update_interval)
    {:noreply, load_videos(socket)}
  end

  # Reload on any event that indicates a video state changed
  @impl true
  def handle_info({event, _data}, socket)
      when event in [
             :encoding_completed,
             :encoding_started,
             :crf_search_completed,
             :crf_search_started,
             :analyzer_progress
           ] do
    {:noreply, load_videos(socket)}
  end

  @impl true
  def handle_info({_event, _data}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("filter_state", %{"state" => state}, socket) do
    filter = if state == "", do: nil, else: state

    socket =
      socket
      |> assign(state_filter: filter, page: 1)
      |> load_videos()

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    socket =
      socket
      |> assign(search: search, page: 1)
      |> load_videos()

    {:noreply, socket}
  end

  @impl true
  def handle_event("sort", %{"col" => col}, socket) do
    col_atom = String.to_existing_atom(col)

    {sort_by, sort_dir} =
      if socket.assigns.sort_by == col_atom do
        {col_atom, toggle_dir(socket.assigns.sort_dir)}
      else
        {col_atom, :asc}
      end

    socket =
      socket
      |> assign(sort_by: sort_by, sort_dir: sort_dir, page: 1)
      |> load_videos()

    {:noreply, socket}
  rescue
    ArgumentError -> {:noreply, socket}
  end

  @impl true
  def handle_event("next_page", _params, socket) do
    max_page = ceil(socket.assigns.total / @per_page)

    if socket.assigns.page < max_page do
      socket =
        socket
        |> assign(page: socket.assigns.page + 1)
        |> load_videos()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("prev_page", _params, socket) do
    if socket.assigns.page > 1 do
      socket =
        socket
        |> assign(page: socket.assigns.page - 1)
        |> load_videos()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("reset_video", %{"id" => id_str}, socket) do
    with {id, _} <- Integer.parse(id_str),
         %{} = video <- Media.get_video(id),
         {:ok, _} <- Media.mark_as_needs_analysis(video) do
      {:noreply, socket |> put_flash(:info, "Video reset to needs_analysis") |> load_videos()}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Video not found")}

      :error ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Reset failed: #{inspect(reason)}")}
    end
  end

  defp load_videos(socket) do
    {videos, total} =
      Media.list_videos_paginated(
        page: socket.assigns.page,
        per_page: @per_page,
        state: socket.assigns.state_filter,
        search: socket.assigns.search,
        sort_by: socket.assigns.sort_by,
        sort_dir: socket.assigns.sort_dir
      )

    assign(socket, videos: videos, total: total)
  end

  defp toggle_dir(:asc), do: :desc
  defp toggle_dir(:desc), do: :asc

  @impl true
  def render(assigns) do
    max_page = ceil(assigns.total / @per_page)
    assigns = assign(assigns, max_page: max(max_page, 1))

    ~H"""
    <div class="min-h-screen bg-gray-900 p-6">
      <div class="max-w-7xl mx-auto space-y-6">
        <div>
          <h1 class="text-3xl font-bold text-white">Videos</h1>
          <p class="text-gray-400">
            {@total} videos total
          </p>
        </div>
        
    <!-- Filters -->
        <div class="flex flex-wrap gap-4 items-center">
          <form phx-change="search" class="flex-1 min-w-[200px]">
            <input
              type="text"
              name="search"
              value={@search}
              placeholder="Search by path..."
              phx-debounce="300"
              class="w-full bg-gray-800 border border-gray-600 text-white rounded px-3 py-2 text-sm focus:ring-purple-500 focus:border-purple-500"
            />
          </form>

          <form phx-change="filter_state">
            <select
              name="state"
              class="bg-gray-800 border border-gray-600 text-white rounded px-3 py-2 text-sm focus:ring-purple-500 focus:border-purple-500"
            >
              <option value="" selected={is_nil(@state_filter)}>All states</option>
              <%= for s <- valid_states() do %>
                <option value={s} selected={@state_filter == s}>{s}</option>
              <% end %>
            </select>
          </form>
        </div>
        
    <!-- Table -->
        <div class="bg-gray-800 rounded-lg border border-gray-700 overflow-hidden">
          <table class="min-w-full divide-y divide-gray-700">
            <thead class="bg-gray-750">
              <tr>
                <.sort_header col={:path} label="Path" sort_by={@sort_by} sort_dir={@sort_dir} />
                <.sort_header col={:state} label="State" sort_by={@sort_by} sort_dir={@sort_dir} />
                <.sort_header col={:size} label="Size" sort_by={@sort_by} sort_dir={@sort_dir} />
                <.sort_header
                  col={:width}
                  label="Resolution"
                  sort_by={@sort_by}
                  sort_dir={@sort_dir}
                />
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider">
                  Codecs
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider">
                  HDR
                </th>
                <.sort_header
                  col={:updated_at}
                  label="Updated"
                  sort_by={@sort_by}
                  sort_dir={@sort_dir}
                />
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider">
                  Actions
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-700">
              <%= for video <- @videos do %>
                <tr class="hover:bg-gray-750">
                  <td class="px-4 py-3 text-sm text-gray-300 max-w-md truncate" title={video.path}>
                    {Path.basename(video.path)}
                  </td>
                  <td class="px-4 py-3 text-sm">
                    <span class={"inline-flex items-center px-2 py-0.5 rounded text-xs font-medium #{state_color(video.state)}"}>
                      {video.state}
                    </span>
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-300">
                    {format_size(video.size)}
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-300">
                    <%= if video.width && video.height do %>
                      {video.width}x{video.height}
                    <% end %>
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-300">
                    {Enum.join(video.video_codecs || [], ", ")}
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-300">
                    {video.hdr || "-"}
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-400">
                    {format_datetime(video.updated_at)}
                  </td>
                  <td class="px-4 py-3 text-sm">
                    <%= if video.state in [:failed, :encoded] do %>
                      <button
                        phx-click="reset_video"
                        phx-value-id={video.id}
                        class="text-purple-400 hover:text-purple-300 text-xs"
                      >
                        Reset
                      </button>
                    <% end %>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
        
    <!-- Pagination -->
        <div class="flex justify-between items-center text-sm text-gray-400">
          <span>
            Page {@page} of {@max_page}
          </span>
          <div class="flex gap-2">
            <button
              phx-click="prev_page"
              disabled={@page <= 1}
              class="px-3 py-1 bg-gray-700 rounded text-gray-300 hover:bg-gray-600 disabled:opacity-50 disabled:cursor-not-allowed"
            >
              Previous
            </button>
            <button
              phx-click="next_page"
              disabled={@page >= @max_page}
              class="px-3 py-1 bg-gray-700 rounded text-gray-300 hover:bg-gray-600 disabled:opacity-50 disabled:cursor-not-allowed"
            >
              Next
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :col, :atom, required: true
  attr :label, :string, required: true
  attr :sort_by, :atom, required: true
  attr :sort_dir, :atom, required: true

  defp sort_header(assigns) do
    active = assigns.col in @sortable_columns

    assigns =
      assign(assigns,
        active: active,
        is_sorted: assigns.sort_by == assigns.col,
        dir: assigns.sort_dir
      )

    ~H"""
    <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider">
      <%= if @active do %>
        <button
          phx-click="sort"
          phx-value-col={@col}
          class={"flex items-center gap-1 uppercase tracking-wider hover:text-white #{if @is_sorted, do: "text-purple-400", else: ""}"}
        >
          {@label}
          <span class="text-xs">
            <%= cond do %>
              <% @is_sorted && @dir == :asc -> %>
                ↑
              <% @is_sorted && @dir == :desc -> %>
                ↓
              <% true -> %>
                ↕
            <% end %>
          </span>
        </button>
      <% else %>
        {@label}
      <% end %>
    </th>
    """
  end

  defp valid_states, do: @valid_states

  defp state_color(state) do
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

  defp format_size(nil), do: "-"
  defp format_size(0), do: "-"

  defp format_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GiB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MiB"
      true -> "#{bytes} B"
    end
  end

  defp format_datetime(nil), do: "-"

  defp format_datetime(%NaiveDateTime{} = dt) do
    dt
    |> NaiveDateTime.to_date()
    |> Date.to_iso8601()
  end

  defp format_datetime(%DateTime{} = dt), do: format_datetime(DateTime.to_naive(dt))
end
