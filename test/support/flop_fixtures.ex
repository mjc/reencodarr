defmodule Reencodarr.FlopFixtures do
  @moduledoc false

  alias Reencodarr.Media.Video

  @doc """
  Builds a `%Flop.Meta{}` for component and LiveView tests without hitting the DB.
  """
  @spec meta_fixture(keyword()) :: Flop.Meta.t()
  def meta_fixture(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    page_size = Keyword.get(opts, :page_size, 20)
    total_count = Keyword.get(opts, :total_count, 0)
    total_pages = total_pages(total_count, page_size)
    current_page = min(max(page, 1), max(total_pages, 1))

    %Flop.Meta{
      schema: Keyword.get(opts, :schema, Video),
      current_page: current_page,
      page_size: page_size,
      total_count: total_count,
      total_pages: total_pages,
      previous_page: if(current_page > 1, do: current_page - 1),
      next_page: if(current_page < total_pages, do: current_page + 1),
      has_previous_page?: current_page > 1,
      has_next_page?: current_page < total_pages,
      flop: %Flop{
        offset: (current_page - 1) * page_size,
        limit: page_size,
        page: current_page,
        page_size: page_size
      }
    }
  end

  defp total_pages(0, _page_size), do: 0

  defp total_pages(total_count, page_size) when total_count > 0 do
    div(total_count + page_size - 1, page_size)
  end
end
