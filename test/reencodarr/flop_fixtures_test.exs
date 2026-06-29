defmodule Reencodarr.FlopFixturesTest do
  use ExUnit.Case, async: true

  alias Reencodarr.FlopFixtures
  alias Reencodarr.Media.Video

  test "meta_fixture/1 defaults to empty first page" do
    meta = FlopFixtures.meta_fixture()

    assert meta.schema == Video
    assert meta.current_page == 1
    assert meta.page_size == 20
    assert meta.total_count == 0
    assert meta.total_pages == 0
    refute meta.has_next_page?
    refute meta.has_previous_page?
  end

  test "meta_fixture/1 builds multi-page meta" do
    meta = FlopFixtures.meta_fixture(page: 2, page_size: 10, total_count: 25)

    assert meta.current_page == 2
    assert meta.total_pages == 3
    assert meta.has_previous_page?
    assert meta.has_next_page?
    assert meta.previous_page == 1
    assert meta.next_page == 3
  end

  test "meta_fixture/1 clamps page beyond total" do
    meta = FlopFixtures.meta_fixture(page: 99, page_size: 10, total_count: 15)

    assert meta.current_page == 2
    assert meta.total_pages == 2
    refute meta.has_next_page?
  end
end
