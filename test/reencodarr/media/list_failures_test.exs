defmodule Reencodarr.Media.ListFailuresTest do
  use Reencodarr.DataCase, async: false

  alias Reencodarr.Fixtures
  alias Reencodarr.Media

  defp failed_video!(attrs) do
    {:ok, video} = Fixtures.video_fixture(attrs)
    Media.record_video_failure(video, :encoding, :timeout, message: "test failure")
    video
  end

  describe "list_failures/1" do
    test "returns failed videos with no filters on page 1" do
      video = failed_video!(%{path: "/media/no_filter.mkv"})

      assert {videos, meta} = Media.list_failures(%{})
      assert meta.total_count == 1
      assert Enum.map(videos, & &1.id) == [video.id]
    end

    test "stage filter limits results" do
      {:ok, analysis_video} = Fixtures.video_fixture(%{path: "/media/analysis_only.mkv"})
      Media.record_video_failure(analysis_video, :analysis, :timeout, message: "analysis")

      {:ok, encoding_video} = Fixtures.video_fixture(%{path: "/media/encoding_only.mkv"})
      Media.record_video_failure(encoding_video, :encoding, :timeout, message: "encoding")

      assert {videos, _meta} = Media.list_failures(%{"stage" => "analysis"})
      assert [%{path: "/media/analysis_only.mkv"}] = videos
    end

    test "category filter limits results" do
      {:ok, process_video} = Fixtures.video_fixture(%{path: "/media/process_fail.mkv"})
      Media.record_video_failure(process_video, :encoding, :process_failure, message: "process")

      {:ok, timeout_video} = Fixtures.video_fixture(%{path: "/media/timeout_fail.mkv"})
      Media.record_video_failure(timeout_video, :encoding, :timeout, message: "timeout")

      assert {videos, _meta} = Media.list_failures(%{"category" => "timeout"})
      assert [%{path: "/media/timeout_fail.mkv"}] = videos
    end

    test "search matches path" do
      failed_video!(%{path: "/media/FindMe_Special.mkv"})
      failed_video!(%{path: "/media/other_file.mkv"})

      assert {videos, meta} = Media.list_failures(%{"search" => "findme"})
      assert meta.total_count == 1
      assert hd(videos).path =~ "FindMe"
    end

    test "pagination returns page 2 slice" do
      Enum.each(1..21, fn n ->
        failed_video!(%{path: "/media/page_#{n}.mkv"})
      end)

      assert {page1, meta1} = Media.list_failures(%{"page" => "1", "page_size" => "20"})
      assert {page2, meta2} = Media.list_failures(%{"page" => "2", "page_size" => "20"})

      assert meta1.total_count == 21
      assert meta2.total_count == 21
      assert 20 == Enum.count(page1)
      assert [_only] = page2
    end

    test "invalid stage coerces to all" do
      video = failed_video!(%{path: "/media/invalid_stage.mkv"})

      assert {videos, meta} = Media.list_failures(%{"stage" => "not_a_stage"})
      assert meta.total_count == 1
      assert hd(videos).id == video.id
    end
  end
end
