defmodule Reencodarr.Media.SharedQueriesTest do
  use ExUnit.Case, async: false

  alias Reencodarr.Media.SharedQueries

  # Helper to create a video-like struct with a path field
  defp video(path), do: %{path: path}

  # Ensure no exclude patterns are configured for most tests
  setup do
    original = Application.get_env(:reencodarr, :exclude_patterns, [])
    Application.put_env(:reencodarr, :exclude_patterns, [])

    on_exit(fn ->
      Application.put_env(:reencodarr, :exclude_patterns, original)
    end)

    :ok
  end

  describe "case_insensitive_like/2" do
    test "returns an Ecto.Query.DynamicExpr struct" do
      result = SharedQueries.case_insensitive_like(:state, "%encoded%")
      assert is_struct(result)
    end

    test "accepts field name and binary pattern" do
      result = SharedQueries.case_insensitive_like(:path, "%shows%")
      assert is_struct(result)
    end
  end

  describe "videos_not_matching_exclude_patterns/1" do
    test "returns empty list for empty input" do
      assert [] == SharedQueries.videos_not_matching_exclude_patterns([])
    end

    test "returns all videos when no exclude patterns configured" do
      videos = [video("/media/show.mkv"), video("/media/movie.mkv")]
      result = SharedQueries.videos_not_matching_exclude_patterns(videos)
      assert result == videos
    end

    test "returns single video unchanged when no patterns" do
      videos = [video("/media/show/S01/ep1.mkv")]
      assert SharedQueries.videos_not_matching_exclude_patterns(videos) == videos
    end

    test "filters out videos matching an exclude pattern" do
      Application.put_env(:reencodarr, :exclude_patterns, ["**/Extras/**"])

      videos = [
        video("/media/show/Extras/behind-the-scenes.mkv"),
        video("/media/show/S01/ep1.mkv")
      ]

      result = SharedQueries.videos_not_matching_exclude_patterns(videos)
      assert length(result) == 1
      assert hd(result).path == "/media/show/S01/ep1.mkv"
    end

    test "filters out all videos when all match exclude pattern" do
      Application.put_env(:reencodarr, :exclude_patterns, ["**/Extras/**"])

      videos = [
        video("/media/show/Extras/deleted.mkv"),
        video("/media/show/Extras/blooper.mkv")
      ]

      result = SharedQueries.videos_not_matching_exclude_patterns(videos)
      assert result == []
    end

    test "handles large list (>= 50 items) returning all when no patterns" do
      videos = Enum.map(1..60, fn i -> video("/media/show/S01/ep#{i}.mkv") end)
      result = SharedQueries.videos_not_matching_exclude_patterns(videos)
      assert length(result) == 60
    end

    test "handles large list (>= 50 items) with an exclude pattern" do
      Application.put_env(:reencodarr, :exclude_patterns, ["**/Extras/**"])

      regular = Enum.map(1..55, fn i -> video("/media/show/S01/ep#{i}.mkv") end)
      extra = [video("/media/show/Extras/deleted.mkv")]
      videos = regular ++ extra

      result = SharedQueries.videos_not_matching_exclude_patterns(videos)
      assert length(result) == 55
    end
  end

  describe "videos_with_no_chosen_vmafs_query/0" do
    test "returns an Ecto.Query struct" do
      result = SharedQueries.videos_with_no_chosen_vmafs_query()
      assert %Ecto.Query{} = result
    end
  end

  describe "video_stats_query/0" do
    test "returns an Ecto.Query struct" do
      result = SharedQueries.video_stats_query()
      assert %Ecto.Query{} = result
    end
  end

  describe "vmaf_stats_query/0" do
    test "returns an Ecto.Query struct" do
      result = SharedQueries.vmaf_stats_query()
      assert %Ecto.Query{} = result
    end
  end
end
