defmodule Reencodarr.Media.VideoQueriesTest do
  use Reencodarr.DataCase, async: true
  alias Reencodarr.Media.VideoQueries

  describe "videos_for_crf_search/1" do
    test "returns videos needing CRF search" do
      # Create a video that should be included
      video =
        video_fixture(%{
          path: "/test/sample_included.mkv",
          reencoded: false,
          failed: false,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      # Create a video that should be excluded (already reencoded)
      _excluded_video =
        video_fixture(%{
          path: "/test/sample_excluded.mkv",
          reencoded: true,
          failed: false,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      results = VideoQueries.videos_for_crf_search(10)

      # Find the specific video in the results
      included_video = Enum.find(results, fn v -> v.id == video.id end)

      assert included_video != nil, "Expected video to be included in CRF search results"
    end

    test "excludes videos with non-h264 codec" do
      # Create a video with av1 codec (should be excluded)
      _excluded_video =
        video_fixture(%{
          reencoded: false,
          failed: false,
          video_codecs: ["av1"],
          audio_codecs: ["aac"]
        })

      results = VideoQueries.videos_for_crf_search(10)

      # Find the specific video in the results
      excluded_video = Enum.find(results, fn v -> "av1" in v.video_codecs end)

      assert excluded_video == nil, "Expected video with av1 codec to be excluded"
    end
  end

  describe "videos_needing_analysis/1" do
    test "returns videos with nil bitrate" do
      video =
        video_fixture(%{
          path: "/test/sample_analysis.mkv",
          bitrate: nil,
          reencoded: false,
          failed: false
        })

      results = VideoQueries.videos_needing_analysis(10)

      # Find the video by path since the result is a map, not a full struct
      found_video = Enum.find(results, fn v -> v.path == video.path end)

      assert found_video != nil, "Expected video with nil bitrate to need analysis"
      assert found_video.path == "/test/sample_analysis.mkv"
    end

    test "excludes videos that don't need analysis" do
      video =
        video_fixture(%{
          path: "/test/sample_no_analysis.mkv",
          bitrate: 5_000_000,
          reencoded: false,
          failed: false
        })

      results = VideoQueries.videos_needing_analysis(10)

      # This video should not be in the results since it has bitrate
      found_video = Enum.find(results, fn v -> v.path == video.path end)

      assert found_video == nil, "Expected video with bitrate to not need analysis"
    end
  end
end
