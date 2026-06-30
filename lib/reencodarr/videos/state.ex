defmodule Reencodarr.Videos.State do
  @moduledoc false

  alias Reencodarr.Media

  @spec load(map(), keyword()) :: map()
  def load(assigns, opts \\ []) do
    include_state_counts? = Keyword.get(opts, :include_state_counts, true)

    {videos, meta} = list_videos(assigns)

    total = meta.total_count || 0
    per_page = meta.page_size || assigns.per_page
    page = min(max(assigns.page, 1), total_pages(total, per_page))

    {videos, meta} =
      if page != assigns.page and total > 0 do
        assigns
        |> Map.put(:page, page)
        |> list_videos()
      else
        {videos, meta}
      end

    state_counts =
      if include_state_counts? do
        Media.count_videos_by_state()
      else
        Map.get(assigns, :state_counts, %{})
      end

    %{
      videos: videos,
      meta: meta,
      total: total,
      page: page,
      per_page: per_page,
      state_counts: state_counts
    }
  end

  defp list_videos(assigns) do
    Media.list_videos_paginated(
      page: assigns.page,
      per_page: assigns.per_page,
      state: assigns.state_filter,
      service_type: assigns.service_filter,
      hdr: assigns.hdr_filter,
      search: assigns.search,
      sort_by: assigns.sort_by,
      sort_dir: assigns.sort_dir
    )
  end

  defp total_pages(total, _per_page) when total <= 0, do: 1
  defp total_pages(total, per_page), do: max(ceil(total / per_page), 1)
end
