defmodule Reencodarr.Videos.State do
  @moduledoc false

  alias Reencodarr.Media

  @spec load(map(), keyword()) :: map()
  def load(assigns, opts \\ []) do
    include_state_counts? = Keyword.get(opts, :include_state_counts, true)

    {videos, meta} =
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

    state_counts =
      if include_state_counts? do
        Media.count_videos_by_state()
      else
        Map.get(assigns, :state_counts, %{})
      end

    %{
      videos: videos,
      meta: meta,
      total: meta.total_count || 0,
      page: meta.current_page || assigns.page,
      per_page: meta.page_size || assigns.per_page,
      state_counts: state_counts
    }
  end
end
