defmodule Reencodarr.Media.ChartQueriesTest do
  use Reencodarr.DataCase

  alias Reencodarr.Media.ChartQueries

  describe "vmaf_score_distribution/0" do
    test "returns histogram bins in configured order" do
      {:ok, video1} =
        Fixtures.video_fixture(%{path: "/test/vmaf_bin_1.mkv", state: :crf_searched})

      {:ok, video2} =
        Fixtures.video_fixture(%{path: "/test/vmaf_bin_2.mkv", state: :crf_searched})

      vmaf1 = Fixtures.vmaf_fixture(%{video_id: video1.id, score: 84.2, crf: 24.0})
      vmaf2 = Fixtures.vmaf_fixture(%{video_id: video2.id, score: 97.3, crf: 28.0})

      Fixtures.choose_vmaf(video1, vmaf1)
      Fixtures.choose_vmaf(video2, vmaf2)

      assert ChartQueries.vmaf_score_distribution() == [
               {"<80", 0},
               {"80-85", 1},
               {"85-90", 0},
               {"90-92", 0},
               {"92-94", 0},
               {"94-96", 0},
               {"96-98", 1},
               {"98+", 0}
             ]
    end
  end

  describe "resolution_distribution/0" do
    test "groups non-failed videos into resolution buckets" do
      {:ok, _video1} =
        Fixtures.video_fixture(%{
          path: "/test/res_4k.mkv",
          width: 3840,
          state: :analyzed
        })

      {:ok, _video2} =
        Fixtures.video_fixture(%{
          path: "/test/res_1080.mkv",
          width: 1920,
          state: :encoded
        })

      {:ok, _video3} =
        Fixtures.video_fixture(%{
          path: "/test/res_failed.mkv",
          width: 1280,
          state: :failed
        })

      assert ChartQueries.resolution_distribution() == [
               {"4K+", 1},
               {"1080p", 1}
             ]
    end
  end

  describe "codec_distribution/0" do
    test "returns normalized top codec counts" do
      {:ok, _video1} =
        Fixtures.video_fixture(%{
          path: "/test/codec_hevc.mkv",
          video_codecs: ["hevc"],
          state: :analyzed
        })

      {:ok, _video2} =
        Fixtures.video_fixture(%{
          path: "/test/codec_h264.mkv",
          video_codecs: ["h264"],
          state: :analyzed
        })

      {:ok, _video3} =
        Fixtures.video_fixture(%{
          path: "/test/codec_hevc_2.mkv",
          video_codecs: ["x265"],
          state: :analyzed
        })

      assert ChartQueries.codec_distribution() == [
               {"HEVC", 2},
               {"H.264", 1}
             ]
    end
  end
end
