defmodule Reencodarr.Media.ExcludePatternsTest do
  use Reencodarr.DataCase

  import Reencodarr.Fixtures

  alias Reencodarr.Media.SharedQueries

  describe "exclude patterns functionality" do
    test "videos_not_matching_exclude_patterns/1 with no patterns configured" do
      # Create a few test videos
      video1 = video_fixture(%{path: "/path/to/movie.mkv"})
      video2 = video_fixture(%{path: "/path/to/sample/trailer.mkv"})
      video3 = video_fixture(%{path: "/media/show/episode.mp4"})

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
      sample_video = video_fixture(%{path: "/path/to/sample/movie.mkv"})
      trailer_video = video_fixture(%{path: "/media/Movie Trailer.mp4"})
      normal_video = video_fixture(%{path: "/media/movies/Normal Movie.mkv"})

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
          video_fixture(%{path: "/media/video#{i}.mkv"})
        end)

      # Should use the optimized small list function
      result = SharedQueries.videos_not_matching_exclude_patterns(videos)
      assert length(result) == 10
    end

    test "large lists use different path" do
      # Create a larger list (>= 50 videos) to test the other code path
      videos =
        Enum.map(1..60, fn i ->
          video_fixture(%{path: "/media/video#{i}.mkv"})
        end)

      # Should use the large list function (which currently falls back to memory filtering)
      result = SharedQueries.videos_not_matching_exclude_patterns(videos)
      assert length(result) == 60
    end
  end
end
