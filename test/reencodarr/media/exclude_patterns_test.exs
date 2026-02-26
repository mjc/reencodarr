defmodule Reencodarr.Media.ExcludePatternsTest do
  use Reencodarr.DataCase
  @moduletag capture_log: true
  import ExUnit.CaptureLog

  import Reencodarr.Fixtures
  import Ecto.Query

  alias Reencodarr.Media.{SharedQueries, Video}
  alias Reencodarr.Repo

  describe "case_insensitive_like/2" do
    test "creates dynamic query fragment for case-insensitive LIKE" do
      # Create videos with different cases
      {:ok, _video1} = video_fixture(%{path: "/media/UPPERCASE.mkv"})
      {:ok, _video2} = video_fixture(%{path: "/media/lowercase.mkv"})
      {:ok, _video3} = video_fixture(%{path: "/media/MixedCase.mkv"})

      # Test case-insensitive search using the function
      query =
        from(v in Video,
          where: ^SharedQueries.case_insensitive_like(:path, "%uppercase%")
        )

      results = Repo.all(query)
      assert length(results) == 1
      assert hd(results).path == "/media/UPPERCASE.mkv"
    end

    test "handles wildcards correctly" do
      {:ok, _video1} = video_fixture(%{path: "/media/test/file1.mkv"})
      {:ok, _video2} = video_fixture(%{path: "/media/test/file2.mp4"})
      {:ok, _video3} = video_fixture(%{path: "/other/path/file3.mkv"})

      query =
        from(v in Video,
          where: ^SharedQueries.case_insensitive_like(:path, "%/media/test/%")
        )

      results = Repo.all(query)
      assert length(results) == 2
    end

    test "works with different field types" do
      {:ok, video} = video_fixture(%{path: "/media/test.mkv", title: "MyTitle"})

      query =
        from(v in Video,
          where: ^SharedQueries.case_insensitive_like(:title, "%mytitle%")
        )

      results = Repo.all(query)
      assert length(results) == 1
      assert hd(results).id == video.id
    end
  end

  describe "exclude patterns functionality" do
    test "videos_not_matching_exclude_patterns/1 with no patterns configured" do
      # Create a few test videos
      {:ok, video1} = video_fixture(%{path: "/path/to/movie.mkv"})
      {:ok, video2} = video_fixture(%{path: "/path/to/sample/trailer.mkv"})
      {:ok, video3} = video_fixture(%{path: "/media/show/episode.mp4"})

      videos = [video1, video2, video3]

      # With no patterns configured, all videos should be returned
      result = SharedQueries.videos_not_matching_exclude_patterns(videos)
      assert length(result) == 3
      assert Enum.map(result, & &1.id) == Enum.map(videos, & &1.id)
    end

    test "pattern matching works with basic glob patterns" do
      # Test the internal pattern matching function via integration test
      # Since the function is private, we test through the public API

      # Create videos with different paths
      {:ok, sample_video} = video_fixture(%{path: "/path/to/sample/movie.mkv"})
      {:ok, trailer_video} = video_fixture(%{path: "/media/Movie Trailer.mp4"})
      {:ok, normal_video} = video_fixture(%{path: "/media/movies/Normal Movie.mkv"})

      videos = [sample_video, trailer_video, normal_video]

      # Test that we can filter videos (this test ensures the pattern matching logic works)
      # We can't easily test with mocked patterns without more complex setup,
      # but we can verify the function doesn't crash and handles empty patterns correctly
      result = SharedQueries.videos_not_matching_exclude_patterns(videos)

      # With no patterns configured, should return all videos
      assert length(result) == 3
    end

    test "small lists use optimized path" do
      # Create a small list (< 50 videos)
      videos =
        Enum.map(1..10, fn i ->
          {:ok, video} = video_fixture(%{path: "/media/video#{i}.mkv"})
          video
        end)

      # Should use the optimized small list function
      result = SharedQueries.videos_not_matching_exclude_patterns(videos)
      assert length(result) == 10
    end

    test "large lists use different path" do
      # Create a larger list (>= 50 videos) to test the other code path
      videos =
        Enum.map(1..60, fn i ->
          {:ok, video} = video_fixture(%{path: "/media/video#{i}.mkv"})
          video
        end)

      # Should use the large list function (which currently falls back to memory filtering)
      result = SharedQueries.videos_not_matching_exclude_patterns(videos)
      assert length(result) == 60
    end

    test "filters videos matching exclude patterns in small lists" do
      # Set exclude patterns
      Application.put_env(:reencodarr, :exclude_patterns, ["**/sample/**", "**/*Trailer*"])

      {:ok, sample_video} = video_fixture(%{path: "/media/sample/movie.mkv"})
      {:ok, trailer_video} = video_fixture(%{path: "/media/Movie Trailer.mp4"})
      {:ok, normal_video} = video_fixture(%{path: "/media/Normal Movie.mkv"})

      videos = [sample_video, trailer_video, normal_video]

      result = SharedQueries.videos_not_matching_exclude_patterns(videos)

      # Should only return normal_video
      assert length(result) == 1
      assert hd(result).id == normal_video.id

      # Clean up
      Application.delete_env(:reencodarr, :exclude_patterns)
    end

    test "filters videos matching exclude patterns in large lists" do
      # Set exclude patterns
      Application.put_env(:reencodarr, :exclude_patterns, ["**/sample/**"])

      # Create 50+ videos with some matching patterns
      normal_videos =
        Enum.map(1..45, fn i ->
          {:ok, video} = video_fixture(%{path: "/media/video#{i}.mkv"})
          video
        end)

      sample_videos =
        Enum.map(1..10, fn i ->
          {:ok, video} = video_fixture(%{path: "/media/sample/video#{i}.mkv"})
          video
        end)

      all_videos = normal_videos ++ sample_videos

      result = SharedQueries.videos_not_matching_exclude_patterns(all_videos)

      # Should only return the 45 normal videos
      assert length(result) == 45
      assert Enum.all?(result, fn v -> not String.contains?(v.path, "/sample/") end)

      # Clean up
      Application.delete_env(:reencodarr, :exclude_patterns)
    end
  end

  describe "videos_with_no_chosen_vmafs_query/0" do
    test "returns video IDs with no chosen VMAFs" do
      {:ok, video1} = video_fixture(%{path: "/media/video1.mkv"})
      {:ok, video2} = video_fixture(%{path: "/media/video2.mkv"})
      {:ok, video3} = video_fixture(%{path: "/media/video3.mkv"})

      # Video1: has unchosen VMAFs only
      _vmaf1 = vmaf_fixture(%{video_id: video1.id, chosen: false, crf: 25.0})
      _vmaf2 = vmaf_fixture(%{video_id: video1.id, chosen: false, crf: 26.0})

      # Video2: has chosen VMAF
      _vmaf3 = vmaf_fixture(%{video_id: video2.id, chosen: true, crf: 25.0})
      _vmaf4 = vmaf_fixture(%{video_id: video2.id, chosen: false, crf: 26.0})

      # Video3: has no VMAFs at all (should not be in results)

      # Query should return only video1 (has VMAFs but none chosen)
      query = SharedQueries.videos_with_no_chosen_vmafs_query()
      video_ids = Repo.all(query)

      assert length(video_ids) == 1
      assert video1.id in video_ids
      refute video2.id in video_ids
      refute video3.id in video_ids
    end

    test "handles video with multiple unchosen VMAFs" do
      {:ok, video} = video_fixture(%{path: "/media/test.mkv"})

      # Add multiple unchosen VMAFs
      _vmaf1 = vmaf_fixture(%{video_id: video.id, chosen: false, crf: 20.0})
      _vmaf2 = vmaf_fixture(%{video_id: video.id, chosen: false, crf: 25.0})
      _vmaf3 = vmaf_fixture(%{video_id: video.id, chosen: false, crf: 30.0})

      query = SharedQueries.videos_with_no_chosen_vmafs_query()
      video_ids = Repo.all(query)

      assert length(video_ids) == 1
      assert video.id in video_ids
    end

    test "excludes videos with at least one chosen VMAF" do
      {:ok, video} = video_fixture(%{path: "/media/test.mkv"})

      # Mix of chosen and unchosen
      _vmaf1 = vmaf_fixture(%{video_id: video.id, chosen: false, crf: 20.0})
      _vmaf2 = vmaf_fixture(%{video_id: video.id, chosen: true, crf: 25.0})
      _vmaf3 = vmaf_fixture(%{video_id: video.id, chosen: false, crf: 30.0})

      query = SharedQueries.videos_with_no_chosen_vmafs_query()
      video_ids = Repo.all(query)

      # Should not include this video since it has a chosen VMAF
      assert Enum.empty?(video_ids)
    end

    test "returns empty list when all videos have chosen VMAFs" do
      {:ok, video1} = video_fixture(%{path: "/media/video1.mkv"})
      {:ok, video2} = video_fixture(%{path: "/media/video2.mkv"})

      _vmaf1 = vmaf_fixture(%{video_id: video1.id, chosen: true, crf: 25.0})
      _vmaf2 = vmaf_fixture(%{video_id: video2.id, chosen: true, crf: 26.0})

      query = SharedQueries.videos_with_no_chosen_vmafs_query()
      video_ids = Repo.all(query)

      assert video_ids == []
    end
  end

  describe "video_stats_query/0" do
    test "returns a valid Ecto query with expected keys" do
      query = SharedQueries.video_stats_query()
      assert %Ecto.Query{} = query

      stats = Repo.one(query)
      assert is_map(stats)

      for key <- ~w[total_videos total_size_gb needs_analysis analyzed crf_searching
                    crf_searched encoding encoded failed avg_duration_minutes]a do
        assert Map.has_key?(stats, key), "missing key: #{key}"
      end
    end

    test "counts all video states correctly, including failed" do
      {:ok, _v1} = video_fixture(%{path: "/v1.mkv"})
      {:ok, v2} = video_fixture(%{path: "/v2.mkv"})
      Repo.update!(Ecto.Changeset.change(v2, state: :analyzed))
      {:ok, v3} = video_fixture(%{path: "/v3.mkv"})
      Repo.update!(Ecto.Changeset.change(v3, state: :crf_searching))
      {:ok, v4} = video_fixture(%{path: "/v4.mkv"})
      Repo.update!(Ecto.Changeset.change(v4, state: :crf_searched))
      {:ok, v5} = video_fixture(%{path: "/v5.mkv"})
      Repo.update!(Ecto.Changeset.change(v5, state: :encoding))
      {:ok, v6} = video_fixture(%{path: "/v6.mkv"})
      Repo.update!(Ecto.Changeset.change(v6, state: :encoded))
      {:ok, v7} = video_fixture(%{path: "/v7.mkv"})
      Repo.update!(Ecto.Changeset.change(v7, state: :failed))

      stats = Repo.one(SharedQueries.video_stats_query())

      assert stats.total_videos == 7
      assert stats.needs_analysis == 1
      assert stats.analyzed == 1
      assert stats.crf_searching == 1
      assert stats.crf_searched == 1
      assert stats.encoding == 1
      assert stats.encoded == 1
      assert stats.failed == 1
    end

    test "calculates average duration correctly" do
      {:ok, _v1} = video_fixture(%{path: "/v1.mkv", duration: 3600})
      {:ok, _v2} = video_fixture(%{path: "/v2.mkv", duration: 7200})

      stats = Repo.one(SharedQueries.video_stats_query())

      assert_in_delta stats.avg_duration_minutes, 90.0, 0.1
    end

    test "handles empty database" do
      stats = Repo.one(SharedQueries.video_stats_query())

      assert stats.total_videos == 0
      assert stats.needs_analysis == 0
    end
  end

  describe "vmaf_stats_query/0" do
    test "returns a valid Ecto query with expected keys" do
      query = SharedQueries.vmaf_stats_query()
      assert %Ecto.Query{} = query

      stats = Repo.one(query)
      assert is_map(stats)

      for key <- ~w[total_vmafs chosen_vmafs total_savings_gb]a do
        assert Map.has_key?(stats, key), "missing key: #{key}"
      end
    end

    test "counts total and chosen VMAFs correctly" do
      {:ok, video1} = video_fixture(%{path: "/v1.mkv", state: :crf_searched})
      {:ok, video2} = video_fixture(%{path: "/v2.mkv", state: :crf_searched})

      _vmaf1 = vmaf_fixture(%{video_id: video1.id, chosen: true, crf: 25.0})
      _vmaf2 = vmaf_fixture(%{video_id: video1.id, chosen: false, crf: 26.0})
      _vmaf3 = vmaf_fixture(%{video_id: video2.id, chosen: false, crf: 25.0})

      stats = Repo.one(SharedQueries.vmaf_stats_query())

      assert stats.total_vmafs == 3
      assert stats.chosen_vmafs == 1
    end

    test "sums savings from chosen VMAFs only" do
      {:ok, video} = video_fixture(%{path: "/v1.mkv", state: :crf_searched})

      # Chosen: 2GB savings
      _vmaf1 =
        vmaf_fixture(%{video_id: video.id, chosen: true, crf: 25.0, savings: 2_147_483_648})

      # Unchosen: should not count
      _vmaf2 =
        vmaf_fixture(%{video_id: video.id, chosen: false, crf: 26.0, savings: 1_073_741_824})

      stats = Repo.one(SharedQueries.vmaf_stats_query())

      assert_in_delta stats.total_savings_gb, 2.0, 0.01
    end

    test "handles empty vmafs table" do
      stats = Repo.one(SharedQueries.vmaf_stats_query())

      assert stats.total_vmafs == 0
      assert stats.chosen_vmafs == 0
      assert stats.total_savings_gb == 0
    end
  end

  describe "get_dashboard_stats/1" do
    test "returns merged map with all dashboard-required keys" do
      capture_log(fn ->
        {:ok, _v1} = video_fixture(%{path: "/v1.mkv", state: :analyzed})
        {:ok, video} = video_fixture(%{path: "/v2.mkv", state: :crf_searched})

        _vmaf =
          vmaf_fixture(%{video_id: video.id, chosen: true, crf: 25.0, savings: 1_073_741_824})

        stats = Reencodarr.Media.get_dashboard_stats()

        assert is_map(stats)

        for key <- ~w[total_videos total_size_gb needs_analysis analyzed crf_searching
                      crf_searched encoding encoded failed total_vmafs chosen_vmafs
                      total_savings_gb]a do
          assert Map.has_key?(stats, key), "missing dashboard key: #{key}"
        end

        assert stats.analyzed == 1
        assert stats.crf_searched == 1
        assert stats.chosen_vmafs == 1
        assert_in_delta stats.total_savings_gb, 1.0, 0.01
      end)
    end

    test "does not produce DB connection errors from spawned tasks" do
      {:ok, _v1} = video_fixture(%{path: "/v_noerror.mkv", state: :analyzed})

      log =
        capture_log(fn ->
          stats = Reencodarr.Media.get_dashboard_stats()
          assert is_map(stats)
          assert stats.total_videos >= 1
        end)

      refute log =~ "owner",
             "get_dashboard_stats should not produce DB ownership errors, got: #{log}"
    end
  end
end
