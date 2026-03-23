defmodule ReencodarrWeb.Live.ListPagination do
  @moduledoc false

  @spec max_page(non_neg_integer(), pos_integer()) :: pos_integer()
  def max_page(total, per_page), do: max(ceil(total / per_page), 1)

  @spec pagination_label(pos_integer(), pos_integer(), non_neg_integer()) :: String.t()
  def pagination_label(page, per_page, total) when total > 0 do
    first = (page - 1) * per_page + 1
    last = min(page * per_page, total)
    "#{first}-#{last} of #{total}"
  end

  def pagination_label(_, _, _), do: "0 results"
end
