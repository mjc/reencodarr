defmodule Reencodarr.Media.VideoQueriesTest do
  use Reencodarr.DataCase, async: true
  alias Reencodarr.Media.VideoQueries
  alias Reencodarr.TestHelpers.VideoHelpers

  describe "videos_for_crf_search/1" do
    test "returns videos needing CRF search" do
      # Create a video that should be included
      video =
        VideoHelpers.create_test_video(%{
          path: "/test/included.mkv",
          reencoded: false,
          failed: false,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      # Create a video that should be excluded (AV1)
      _excluded_video =
        VideoHelpers.create_test_video(%{
          path: "/test/excluded.mkv",
          reencoded: false,
          failed: false,
          video_codecs: ["av1"],
          audio_codecs: ["aac"]
        })

      results = VideoQueries.videos_for_crf_search(10)

      # Find the specific video in the results
      included_video = Enum.find(results, fn v -> v.id == video.id end)
      excluded_video = Enum.find(results, fn v -> v.video_codecs == ["av1"] end)

      assert included_video != nil, "Expected video with h264 codec to be included"
      assert excluded_video == nil, "Expected video with av1 codec to be excluded"
    end
  end

  describe "videos_needing_analysis/1" do
    test "returns videos with nil bitrate" do
      video =
        VideoHelpers.create_test_video(%{
          bitrate: nil,
          failed: false
        })

      _analyzed_video =
        VideoHelpers.create_test_video(%{
          path: "/test/analyzed.mkv",
          bitrate: 5000,
          failed: false
        })

      results = VideoQueries.videos_needing_analysis(10)

      assert length(results) == 1
      assert List.first(results).path == video.path
    end
  end

  describe "encoding_queue_count/0" do
    test "counts videos ready for encoding" do
      video = VideoHelpers.create_test_video()
      _vmaf = VideoHelpers.create_chosen_vmaf(video)

      count = VideoQueries.encoding_queue_count()

      assert count == 1
    end
  end
end
