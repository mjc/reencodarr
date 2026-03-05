defmodule Reencodarr.Media.GlobPatternTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Media.GlobPattern

  describe "new/2" do
    test "creates a struct with the given pattern" do
      gp = GlobPattern.new("*.mp4")
      assert gp.pattern == "*.mp4"
    end

    test "defaults to case-insensitive matching" do
      gp = GlobPattern.new("*.mp4")
      refute gp.case_sensitive
    end

    test "respects case_sensitive option" do
      gp = GlobPattern.new("*.mp4", case_sensitive: true)
      assert gp.case_sensitive
    end

    test "compiles a regex" do
      gp = GlobPattern.new("*.mp4")
      assert %Regex{} = gp.regex
    end
  end

  describe "matches?/2" do
    test "* matches simple filename patterns" do
      gp = GlobPattern.new("*.mp4")
      assert GlobPattern.matches?(gp, "video.mp4")
      assert GlobPattern.matches?(gp, "my.favourite.video.mp4")
    end

    test "* does not cross directory separator" do
      gp = GlobPattern.new("*.mp4")
      refute GlobPattern.matches?(gp, "some/path/video.mp4")
    end

    test "** crosses directory separators" do
      gp = GlobPattern.new("**/*.mp4")
      assert GlobPattern.matches?(gp, "some/deep/path/video.mp4")
    end

    test "? matches a single character" do
      gp = GlobPattern.new("video?.mp4")
      assert GlobPattern.matches?(gp, "video1.mp4")
      assert GlobPattern.matches?(gp, "videoA.mp4")
      refute GlobPattern.matches?(gp, "video12.mp4")
    end

    test "case-insensitive matching by default" do
      gp = GlobPattern.new("*.MP4")
      assert GlobPattern.matches?(gp, "video.mp4")
      assert GlobPattern.matches?(gp, "VIDEO.MP4")
    end

    test "case-sensitive matching when requested" do
      gp = GlobPattern.new("*.MP4", case_sensitive: true)
      assert GlobPattern.matches?(gp, "video.MP4")
      refute GlobPattern.matches?(gp, "video.mp4")
    end

    test "exact match with no wildcards" do
      gp = GlobPattern.new("video.mkv")
      assert GlobPattern.matches?(gp, "video.mkv")
      refute GlobPattern.matches?(gp, "other.mkv")
    end

    test "** matches flat filenames too" do
      gp = GlobPattern.new("**.mkv")
      assert GlobPattern.matches?(gp, "movie.mkv")
      assert GlobPattern.matches?(gp, "dir/movie.mkv")
    end

    test "typical media path pattern" do
      gp = GlobPattern.new("**/Season */*.mkv")
      assert GlobPattern.matches?(gp, "Shows/Breaking Bad/Season 1/E01.mkv")
      # ** requires at least one path component before the /Season literal
      assert GlobPattern.matches?(gp, "Shows/Season 3/episode.mkv")
    end
  end
end
