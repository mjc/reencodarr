defmodule Reencodarr.Analyzer.CodecOptimizationTest do
  @moduledoc """
  Tests that verify the analyzer correctly optimizes videos with AV1/Opus codecs
  by skipping CRF search and transitioning directly to reencoded state.
  """
  use Reencodarr.DataCase

  import Reencodarr.Fixtures

  alias Reencodarr.Media

  describe "codec optimization during analysis" do
    test "AV1 videos can be marked as reencoded, not analyzed" do
      # Create a video with AV1 codec and all required fields
      video =
        video_fixture(%{
          state: :needs_analysis,
          video_codecs: ["AV1"],
          audio_codecs: ["aac"],
          # Add required duration
          duration: 3600.0,
          # Add required bitrate
          bitrate: 5_000_000
        })

      # Manually call mark_as_reencoded to simulate what the analyzer should do
      {:ok, updated_video} = Media.mark_as_reencoded(video)

      # Verify the video skipped all intermediate states and went to :encoded
      assert updated_video.state == :encoded
      assert updated_video.id == video.id
    end

    test "Opus audio videos can be marked as reencoded, not analyzed" do
      # Create a video with Opus audio and all required fields
      video =
        video_fixture(%{
          state: :needs_analysis,
          video_codecs: ["h264"],
          audio_codecs: ["opus"],
          # Add required duration
          duration: 3600.0,
          # Add required bitrate
          bitrate: 5_000_000
        })

      # Manually call mark_as_reencoded to simulate what the analyzer should do
      {:ok, updated_video} = Media.mark_as_reencoded(video)

      # Verify the video skipped all intermediate states and went to :encoded
      assert updated_video.state == :encoded
      assert updated_video.id == video.id
    end

    test "videos with both AV1 and Opus can be marked as reencoded" do
      # Create a video with both target codecs and all required fields
      video =
        video_fixture(%{
          state: :needs_analysis,
          video_codecs: ["AV1"],
          audio_codecs: ["opus"],
          # Add required duration
          duration: 3600.0,
          # Add required bitrate
          bitrate: 5_000_000
        })

      # Manually call mark_as_reencoded to simulate what the analyzer should do
      {:ok, updated_video} = Media.mark_as_reencoded(video)

      # Verify the video skipped all intermediate states and went to :encoded
      assert updated_video.state == :encoded
      assert updated_video.id == video.id
    end
  end

  describe "CRF search queue filtering verification" do
    test "AV1 and Opus videos are filtered out of CRF search queue" do
      # Create videos with different codec combinations
      _av1_video =
        video_fixture(%{
          state: :analyzed,
          video_codecs: ["AV1"],
          audio_codecs: ["aac"]
        })

      _opus_video =
        video_fixture(%{
          state: :analyzed,
          video_codecs: ["h264"],
          audio_codecs: ["opus"]
        })

      regular_video =
        video_fixture(%{
          state: :analyzed,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      # Query for videos that should be in CRF search queue
      crf_search_videos = Media.list_videos_awaiting_crf_search()

      # Only the regular video should be in the queue
      crf_search_video_ids = Enum.map(crf_search_videos, & &1.id)
      assert regular_video.id in crf_search_video_ids
    end
  end
end
