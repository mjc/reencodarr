defmodule ReencodarrWeb.FlopListTestHelpersTest do
  use ExUnit.Case, async: true

  alias Reencodarr.FlopFixtures
  alias ReencodarrWeb.FlopListTestHelpers

  test "current_page_from_meta/1 reads flop meta page" do
    meta = FlopFixtures.meta_fixture(page: 3, page_size: 20, total_count: 60)
    assert FlopListTestHelpers.current_page_from_meta(meta) == 3
  end

  test "assert_filter_in_url/3 matches query params" do
    assert :ok =
             FlopListTestHelpers.assert_filter_in_url(
               "/failures?stage=analysis&search=foo",
               "stage",
               "analysis"
             )
  end

  test "pagination_label_from_html/1 parses flop label" do
    html = ~s(<span data-role="flop-pagination-label">1-20 of 42</span>)
    assert FlopListTestHelpers.pagination_label_from_html(html) == "1-20 of 42"
  end
end
