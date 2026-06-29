defmodule ReencodarrWeb.Live.FlopListTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Reencodarr.FlopFixtures
  alias ReencodarrWeb.Live.FlopList

  describe "flop_pagination/1" do
    test "simple mode renders label and prev/next without page numbers" do
      meta = FlopFixtures.meta_fixture(page: 2, page_size: 50, total_count: 120)

      html =
        render_component(&FlopList.flop_pagination/1, %{
          id: "videos-flop-pagination",
          meta: meta,
          path: "/videos",
          mode: :simple
        })

      assert html =~ "id=\"videos-flop-pagination\""
      assert html =~ ~s(data-role="flop-pagination-label")
      assert html =~ "51-100 of 120"
      assert html =~ ~s(data-role="flop-pagination-prev")
      assert html =~ ~s(data-role="flop-pagination-next")
      assert html =~ "bg-gray-700"
      refute html =~ ~s(aria-current="page")
    end

    test "base_path builds patch links preserving custom query params" do
      meta = FlopFixtures.meta_fixture(page: 1, page_size: 50, total_count: 120)

      html =
        render_component(&FlopList.flop_pagination/1, %{
          meta: meta,
          base_path: "/videos",
          query: %{
            "sort_by" => "updated_at",
            "sort_dir" => "desc",
            "per_page" => 50
          },
          mode: :simple
        })

      assert html =~ "sort_by=updated_at"
      assert html =~ "sort_dir=desc"
      assert html =~ "per_page=50"
    end

    test "full mode renders numbered page links" do
      meta = FlopFixtures.meta_fixture(page: 5, page_size: 20, total_count: 200)

      html =
        render_component(&FlopList.flop_pagination/1, %{
          id: "failures-flop-pagination",
          meta: meta,
          path: "/failures",
          mode: :full,
          page_links: 5
        })

      assert html =~ "id=\"failures-flop-pagination\""
      assert html =~ ~s(data-role="flop-pagination-page")
      assert html =~ "bg-blue-600"
    end

    test "simple mode disables previous on first page" do
      meta = FlopFixtures.meta_fixture(page: 1, page_size: 10, total_count: 25)

      html =
        render_component(&FlopList.flop_pagination/1, %{
          meta: meta,
          path: "/videos",
          mode: :simple
        })

      assert html =~ "disabled"
      assert html =~ "opacity-40"
    end
  end

  describe "pagination_label/1" do
    test "delegates to range label from meta" do
      meta = FlopFixtures.meta_fixture(page: 1, page_size: 10, total_count: 5)

      assert FlopList.pagination_label(meta) == "1-5 of 5"
    end

    test "clamps oversized current_page before building the label" do
      meta = %Flop.Meta{current_page: 999_999, page_size: 10, total_count: 25}

      assert FlopList.pagination_label(meta) == "21-25 of 25"
    end
  end

  describe "patch_with_page/3" do
    test "omits page param on first page" do
      url = FlopList.patch_with_page("/videos", %{"per_page" => 50}, 1)

      assert %URI{path: "/videos", query: query} = URI.parse(url)
      assert URI.decode_query(query) == %{"per_page" => "50"}
    end

    test "includes page param when not on first page" do
      url = FlopList.patch_with_page("/videos", %{"per_page" => 50}, 2)

      assert %URI{path: "/videos", query: query} = URI.parse(url)
      assert URI.decode_query(query) == %{"page" => "2", "per_page" => "50"}
    end

    test "returns bare path when merged query is empty" do
      assert FlopList.patch_with_page("/bad-files", %{}, 1) == "/bad-files"
    end
  end

  describe "parse_page/3" do
    test "clamps page to total pages when total and per_page given" do
      assert FlopList.parse_page(%{"page" => "99"}, 1, total: 25, per_page: 10) == 3
    end
  end

  describe "parse_per_page/3" do
    test "falls back to default for invalid per_page" do
      assert FlopList.parse_per_page(%{"per_page" => "13"}, 25, [25, 50, 100]) == 25
    end
  end

  describe "pagination_assigns/4" do
    test "returns assign-ready page and per_page values" do
      assert FlopList.pagination_assigns(%{"page" => "4", "per_page" => "50"}, 25, [25, 50]) ==
               %{page: 4, per_page: 50}
    end

    test "coerces invalid values to safe defaults" do
      assert FlopList.pagination_assigns(%{"page" => "0", "per_page" => "13"}, 25, [25, 50]) ==
               %{page: 1, per_page: 25}
    end
  end

  describe "total_pages/2" do
    test "returns at least one page" do
      assert FlopList.total_pages(0, 10) == 1
      assert FlopList.total_pages(21, 10) == 3
    end
  end
end
