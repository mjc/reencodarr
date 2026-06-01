defmodule ReencodarrWeb.Live.ListPaginationTest do
  @moduledoc """
  Tests for the ListPagination helper module.
  """
  use ExUnit.Case, async: true

  alias ReencodarrWeb.Live.ListPagination

  describe "max_page/2" do
    test "returns 1 for zero total items" do
      assert ListPagination.max_page(0, 10) == 1
    end

    test "returns 1 when items fit in one page" do
      assert ListPagination.max_page(10, 10) == 1
    end

    test "returns 1 for fewer items than per_page" do
      assert ListPagination.max_page(5, 10) == 1
    end

    test "returns 2 when one item overflows to second page" do
      assert ListPagination.max_page(11, 10) == 2
    end

    test "returns 2 when items fill exactly two pages" do
      assert ListPagination.max_page(20, 10) == 2
    end

    test "returns 3 when one item overflows to third page" do
      assert ListPagination.max_page(21, 10) == 3
    end

    test "returns correct page count for large datasets" do
      assert ListPagination.max_page(100, 10) == 10
      assert ListPagination.max_page(250, 50) == 5
      assert ListPagination.max_page(1000, 25) == 40
    end

    test "always returns at least 1 even with 0 items" do
      assert ListPagination.max_page(0, 1) >= 1
      assert ListPagination.max_page(0, 100) >= 1
    end

    test "handles single item per page" do
      assert ListPagination.max_page(1, 1) == 1
      assert ListPagination.max_page(5, 1) == 5
      assert ListPagination.max_page(10, 1) == 10
    end

    test "result is always a positive integer" do
      for total <- [0, 1, 5, 10, 100, 999],
          per_page <- [1, 10, 25, 50, 100] do
        result = ListPagination.max_page(total, per_page)
        assert is_integer(result), "Expected integer for max_page(#{total}, #{per_page})"
        assert result >= 1, "Expected >= 1 for max_page(#{total}, #{per_page})"
      end
    end
  end

  describe "pagination_label/3" do
    test "returns '0 results' when total is 0" do
      assert ListPagination.pagination_label(1, 10, 0) == "0 results"
    end

    test "returns range for first page with full page of items" do
      assert ListPagination.pagination_label(1, 10, 10) == "1-10 of 10"
    end

    test "returns range for first page with partial items" do
      assert ListPagination.pagination_label(1, 10, 5) == "1-5 of 5"
    end

    test "returns correct range for second page" do
      assert ListPagination.pagination_label(2, 10, 15) == "11-15 of 15"
    end

    test "returns correct range for second full page" do
      assert ListPagination.pagination_label(2, 10, 20) == "11-20 of 20"
    end

    test "last page with partial items shows correct range" do
      assert ListPagination.pagination_label(3, 10, 25) == "21-25 of 25"
    end

    test "first item on a page is always (page-1)*per_page + 1" do
      # Page 1: first = 1
      assert ListPagination.pagination_label(1, 25, 30) =~ "1-"
      # Page 2: first = 26
      assert ListPagination.pagination_label(2, 25, 30) =~ "26-"
    end

    test "total is always shown correctly after 'of'" do
      assert ListPagination.pagination_label(1, 10, 42) =~ "of 42"
      assert ListPagination.pagination_label(2, 10, 42) =~ "of 42"
    end

    test "last item does not exceed total" do
      # Page 5, per_page 10, total 42 → should show 41-42 not 41-50
      assert ListPagination.pagination_label(5, 10, 42) == "41-42 of 42"
    end

    test "with per_page=20 defaults as in failures_live" do
      # Matches FailuresLive @per_page default
      assert ListPagination.pagination_label(1, 20, 0) == "0 results"
      assert ListPagination.pagination_label(1, 20, 15) == "1-15 of 15"
      assert ListPagination.pagination_label(1, 20, 20) == "1-20 of 20"
      assert ListPagination.pagination_label(2, 20, 25) == "21-25 of 25"
    end
  end
end
