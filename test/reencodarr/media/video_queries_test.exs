defmodule Reencodarr.Media.VideoQueriesTest do
  use Reencodarr.DataCase, async: true
  alias Reencodarr.Media.VideoQueries

  describe "videos_for_crf_search/1" do
    test "returns videos needing CRF search" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/sample.mkv",
          # Video must be analyzed to be eligible for CRF search
          state: :analyzed,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      # Create a video that should be excluded (already reencoded)
      {:ok, _excluded_video} =
        Fixtures.video_fixture(%{
          path: "/test/sample_excluded.mkv",
          # Encoded videos should be excluded
          state: :encoded,
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
      {:ok, _excluded_video} =
        Fixtures.video_fixture(%{
          video_codecs: ["av1"],
          audio_codecs: ["aac"]
        })

      results = VideoQueries.videos_for_crf_search(10)

      # Find the specific video in the results
      excluded_video = Enum.find(results, fn v -> "av1" in v.video_codecs end)

      assert excluded_video == nil, "Expected video with av1 codec to be excluded"
    end

    test "orders higher priority videos first" do
      {:ok, low_priority} =
        Fixtures.video_fixture(%{
          path: "/test/crf_low_priority.mkv",
          state: :analyzed,
          bitrate: 12_000_000,
          size: 2_000_000_000,
          priority: 1
        })

      {:ok, high_priority} =
        Fixtures.video_fixture(%{
          path: "/test/crf_high_priority.mkv",
          state: :analyzed,
          bitrate: 8_000_000,
          size: 1_000_000_000,
          priority: 50
        })

      results = VideoQueries.videos_for_crf_search(10)

      assert Enum.take(Enum.map(results, & &1.id), 2) == [high_priority.id, low_priority.id]
    end
  end

  describe "videos_needing_analysis/1" do
    test "returns videos with nil bitrate" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/sample_analysis.mkv",
          bitrate: nil
        })

      # Video with missing bitrate should be in :needs_analysis state
      assert video.state == :needs_analysis

      results = VideoQueries.videos_needing_analysis(10)

      # Find the video by path since the result is a map, not a full struct
      found_video = Enum.find(results, fn v -> v.path == video.path end)

      assert found_video != nil, "Expected video with nil bitrate to need analysis"
      assert found_video.path == video.path
    end

    test "excludes videos that don't need analysis" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/sample_no_analysis.mkv",
          bitrate: 5_000_000,
          width: 1920,
          height: 1080,
          duration: 3600.0,
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          audio_count: 1,
          video_count: 1
        })

      # Update the video to analyzed state to simulate completed analysis
      {:ok, analyzed_video} = Reencodarr.Media.update_video(video, %{state: :analyzed})

      # Video with complete metadata should be in :analyzed state
      assert analyzed_video.state == :analyzed

      results = VideoQueries.videos_needing_analysis(10)

      # This video should not be in the results since it has all essential metadata
      found_video = Enum.find(results, fn v -> v.path == video.path end)

      assert found_video == nil, "Expected video with complete metadata to not need analysis"
    end

    test "orders higher priority videos first" do
      {:ok, low_priority} =
        Fixtures.video_fixture(%{
          path: "/test/analysis_low_priority.mkv",
          bitrate: nil,
          size: 3_000_000_000,
          priority: 1
        })

      {:ok, high_priority} =
        Fixtures.video_fixture(%{
          path: "/test/analysis_high_priority.mkv",
          bitrate: nil,
          size: 1_000_000_000,
          priority: 100
        })

      results = VideoQueries.videos_needing_analysis(10)

      assert Enum.take(Enum.map(results, & &1.id), 2) == [high_priority.id, low_priority.id]
    end
  end

  describe "videos_needing_analysis_preview/1" do
    test "returns only dashboard preview fields" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/analysis_preview.mkv",
          bitrate: nil
        })

      [preview | _] = VideoQueries.videos_needing_analysis_preview(10)

      assert preview.id == video.id
      assert preview.path == video.path
      assert Map.keys(preview) |> Enum.sort() == [:id, :path]
    end
  end

  describe "count_videos_for_crf_search/1" do
    test "counts analyzed videos eligible for CRF search" do
      before_count = VideoQueries.count_videos_for_crf_search()

      {:ok, _video} =
        Fixtures.video_fixture(%{
          path: "/test/count_crf_eligible.mkv",
          state: :analyzed,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      after_count = VideoQueries.count_videos_for_crf_search()
      assert after_count == before_count + 1
    end

    test "does not count encoded videos" do
      before_count = VideoQueries.count_videos_for_crf_search()

      {:ok, _video} =
        Fixtures.video_fixture(%{
          path: "/test/count_crf_encoded.mkv",
          state: :encoded,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      after_count = VideoQueries.count_videos_for_crf_search()
      assert after_count == before_count
    end

    test "does not count needs_analysis videos" do
      before_count = VideoQueries.count_videos_for_crf_search()

      {:ok, _video} =
        Fixtures.video_fixture(%{
          path: "/test/count_crf_unanalyzed.mkv",
          state: :needs_analysis,
          bitrate: nil
        })

      after_count = VideoQueries.count_videos_for_crf_search()
      assert after_count == before_count
    end

    test "returns an integer" do
      result = VideoQueries.count_videos_for_crf_search()
      assert is_integer(result)
      assert result >= 0
    end
  end

  describe "videos_for_crf_search_preview/1" do
    test "returns only dashboard preview fields" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/crf_preview.mkv",
          state: :analyzed,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      [preview | _] = VideoQueries.videos_for_crf_search_preview(10)

      assert preview.id == video.id
      assert preview.path == video.path
      assert Map.keys(preview) |> Enum.sort() == [:id, :path]
    end
  end

  describe "count_videos_needing_analysis/1" do
    test "counts videos in needs_analysis state" do
      before_count = VideoQueries.count_videos_needing_analysis()

      {:ok, _video} =
        Fixtures.video_fixture(%{
          path: "/test/count_analysis_needed.mkv",
          bitrate: nil
        })

      after_count = VideoQueries.count_videos_needing_analysis()
      assert after_count == before_count + 1
    end

    test "does not count analyzed videos" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/count_analysis_analyzed.mkv",
          bitrate: 5_000_000,
          width: 1920,
          height: 1080,
          duration: 3600.0,
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          audio_count: 1,
          video_count: 1
        })

      {:ok, _} = Reencodarr.Media.update_video(video, %{state: :analyzed})

      before_count = VideoQueries.count_videos_needing_analysis()

      # Add one more analyzed video and confirm count stays same
      {:ok, video2} =
        Fixtures.video_fixture(%{
          path: "/test/count_analysis_analyzed2.mkv",
          bitrate: 5_000_000,
          width: 1920,
          height: 1080,
          duration: 3600.0,
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          audio_count: 1,
          video_count: 1
        })

      {:ok, _} = Reencodarr.Media.update_video(video2, %{state: :analyzed})

      after_count = VideoQueries.count_videos_needing_analysis()
      assert after_count == before_count
    end

    test "returns an integer" do
      result = VideoQueries.count_videos_needing_analysis()
      assert is_integer(result)
      assert result >= 0
    end
  end

  describe "videos_ready_for_encoding/2" do
    test "returns videos in crf_searched state with a chosen VMAF" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/ready_for_encoding.mkv",
          state: :analyzed,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 25.0})
      Fixtures.choose_vmaf(video, vmaf)
      {:ok, _} = Reencodarr.Media.update_video(video, %{state: :crf_searched})

      results = VideoQueries.videos_ready_for_encoding(10)
      found = Enum.find(results, fn v -> v.video.id == video.id end)

      assert found != nil,
             "Expected crf_searched video with chosen VMAF to appear in encoding queue"
    end

    test "excludes videos without a chosen VMAF" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/ready_no_vmaf.mkv",
          state: :analyzed,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      {:ok, _} = Reencodarr.Media.update_video(video, %{state: :crf_searched})

      results = VideoQueries.videos_ready_for_encoding(10)
      found = Enum.find(results, fn v -> v.video.id == video.id end)

      assert found == nil, "Expected video without chosen VMAF to be excluded"
    end

    test "excludes videos not in crf_searched state" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/ready_wrong_state.mkv",
          state: :analyzed,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 25.0})
      Fixtures.choose_vmaf(video, vmaf)

      # Leave video in :analyzed state (not :crf_searched)
      results = VideoQueries.videos_ready_for_encoding(10)
      found = Enum.find(results, fn v -> v.video.id == video.id end)

      assert found == nil, "Expected :analyzed video to be excluded from encoding queue"
    end

    test "returns Vmaf structs with preloaded video" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/ready_struct_check.mkv",
          state: :analyzed,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 30.0})
      Fixtures.choose_vmaf(video, vmaf)
      {:ok, _} = Reencodarr.Media.update_video(video, %{state: :crf_searched})

      results = VideoQueries.videos_ready_for_encoding(10)
      found = Enum.find(results, fn v -> v.video.id == video.id end)

      assert %Reencodarr.Media.Vmaf{} = found
      assert %Reencodarr.Media.Video{} = found.video
      assert found.video.id == video.id
    end

    test "orders higher priority videos first" do
      {:ok, low_priority} =
        Fixtures.video_fixture(%{
          path: "/test/encoding_low_priority.mkv",
          state: :analyzed,
          priority: 2
        })

      low_vmaf = Fixtures.vmaf_fixture(%{video_id: low_priority.id, crf: 28.0, savings: 80})
      Fixtures.choose_vmaf(low_priority, low_vmaf)
      {:ok, _} = Reencodarr.Media.update_video(low_priority, %{state: :crf_searched})

      {:ok, high_priority} =
        Fixtures.video_fixture(%{
          path: "/test/encoding_high_priority.mkv",
          state: :analyzed,
          priority: 200
        })

      high_vmaf = Fixtures.vmaf_fixture(%{video_id: high_priority.id, crf: 30.0, savings: 10})
      Fixtures.choose_vmaf(high_priority, high_vmaf)
      {:ok, _} = Reencodarr.Media.update_video(high_priority, %{state: :crf_searched})

      results = VideoQueries.videos_ready_for_encoding(10)

      assert Enum.take(Enum.map(results, & &1.video.id), 2) == [high_priority.id, low_priority.id]
    end
  end

  describe "encoding_queue_count/1" do
    test "counts crf_searched videos with a chosen VMAF" do
      before_count = VideoQueries.encoding_queue_count()

      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/enc_queue_count.mkv",
          state: :analyzed,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 25.0})
      Fixtures.choose_vmaf(video, vmaf)
      {:ok, _} = Reencodarr.Media.update_video(video, %{state: :crf_searched})

      after_count = VideoQueries.encoding_queue_count()
      assert after_count == before_count + 1
    end

    test "does not count encoded videos" do
      before_count = VideoQueries.encoding_queue_count()

      {:ok, _video} =
        Fixtures.video_fixture(%{
          path: "/test/enc_queue_encoded.mkv",
          state: :encoded,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      after_count = VideoQueries.encoding_queue_count()
      assert after_count == before_count
    end

    test "does not count crf_searched videos without chosen VMAF" do
      before_count = VideoQueries.encoding_queue_count()

      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/enc_queue_no_vmaf.mkv",
          state: :analyzed,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      {:ok, _} = Reencodarr.Media.update_video(video, %{state: :crf_searched})

      after_count = VideoQueries.encoding_queue_count()
      assert after_count == before_count
    end

    test "returns an integer" do
      result = VideoQueries.encoding_queue_count()
      assert is_integer(result)
      assert result >= 0
    end
  end

  describe "videos_ready_for_encoding_preview/2" do
    test "returns only dashboard preview fields" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/encoding_preview.mkv",
          state: :analyzed,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 26.0})
      Fixtures.choose_vmaf(video, vmaf)
      {:ok, _} = Reencodarr.Media.update_video(video, %{state: :crf_searched})

      [preview | _] = VideoQueries.videos_ready_for_encoding_preview(10)

      assert preview.id == vmaf.id
      assert preview.video.id == video.id
      assert preview.video.path == video.path
      assert Map.keys(preview) |> Enum.sort() == [:id, :video]
      assert Map.keys(preview.video) |> Enum.sort() == [:id, :path]
    end
  end
end
