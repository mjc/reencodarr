defmodule Reencodarr.Media.Video.MediaInfoConverterTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Media.Video.MediaInfoConverter
  alias Reencodarr.Media.VideoFileInfo

  describe "from_mediainfo_json/1" do
    test "passes through a valid map unchanged" do
      input = %{"media" => %{"track" => []}}
      assert {:ok, ^input} = MediaInfoConverter.from_mediainfo_json(input)
    end

    test "passes through an empty map" do
      assert {:ok, %{}} = MediaInfoConverter.from_mediainfo_json(%{})
    end

    test "returns error for nil input" do
      assert {:error, "invalid mediainfo format"} =
               MediaInfoConverter.from_mediainfo_json(nil)
    end

    test "returns error for binary input" do
      assert {:error, "invalid mediainfo format"} =
               MediaInfoConverter.from_mediainfo_json("not a map")
    end

    test "returns error for list input" do
      assert {:error, "invalid mediainfo format"} =
               MediaInfoConverter.from_mediainfo_json([])
    end

    test "returns error for integer input" do
      assert {:error, "invalid mediainfo format"} =
               MediaInfoConverter.from_mediainfo_json(42)
    end
  end

  defp minimal_vfi(overrides \\ %{}) do
    base = %VideoFileInfo{
      path: "/media/show.mkv",
      size: 1_000_000,
      service_id: "123",
      service_type: :sonarr,
      audio_codec: "AAC",
      bitrate: 5000,
      audio_channels: 2,
      video_codec: "HEVC",
      resolution: {1920, 1080},
      video_fps: 24.0,
      video_dynamic_range: nil,
      video_dynamic_range_type: nil,
      audio_stream_count: 1,
      overall_bitrate: nil,
      run_time: 3600,
      subtitles: [],
      title: nil
    }

    Map.merge(base, overrides)
  end

  describe "from_video_file_info/1" do
    test "returns a map with media.track structure" do
      result = MediaInfoConverter.from_video_file_info(minimal_vfi())

      assert %{"media" => %{"track" => tracks}} = result
      assert is_list(tracks)
      assert length(tracks) == 3
    end

    test "General track has @type General" do
      %{"media" => %{"track" => tracks}} = MediaInfoConverter.from_video_file_info(minimal_vfi())
      general = Enum.find(tracks, &(&1["@type"] == "General"))
      assert general != nil
    end

    test "Video track includes width and height from resolution tuple" do
      %{"media" => %{"track" => tracks}} = MediaInfoConverter.from_video_file_info(minimal_vfi())
      video = Enum.find(tracks, &(&1["@type"] == "Video"))
      assert video["Width"] == 1920
      assert video["Height"] == 1080
    end

    test "Video track maps video codec to CodecID" do
      %{"media" => %{"track" => tracks}} = MediaInfoConverter.from_video_file_info(minimal_vfi())
      video = Enum.find(tracks, &(&1["@type"] == "Video"))
      assert video["CodecID"] == "HEVC"
    end

    test "Audio track includes codec and channels" do
      %{"media" => %{"track" => tracks}} = MediaInfoConverter.from_video_file_info(minimal_vfi())
      audio = Enum.find(tracks, &(&1["@type"] == "Audio"))
      assert audio["CodecID"] == "AAC"
    end

    test "resolution as binary string is parsed" do
      info = minimal_vfi(%{resolution: {640, 480}})
      %{"media" => %{"track" => tracks}} = MediaInfoConverter.from_video_file_info(info)
      video = Enum.find(tracks, &(&1["@type"] == "Video"))
      assert video["Width"] == 640
      assert video["Height"] == 480
    end

    test "nil or invalid resolution falls back to {0, 0}" do
      info = minimal_vfi(%{resolution: nil})
      %{"media" => %{"track" => tracks}} = MediaInfoConverter.from_video_file_info(info)
      video = Enum.find(tracks, &(&1["@type"] == "Video"))
      assert video["Width"] == 0
      assert video["Height"] == 0
    end
  end

  defp minimal_service_file(overrides \\ %{}) do
    base = %{
      "path" => "/media/show.mkv",
      "size" => 2_000_000,
      "id" => 1,
      "runTime" => 3600,
      "overallBitrate" => 5000,
      "videoFps" => 23.976,
      "sceneName" => "Show.S01E01",
      "dateAdded" => "2024-01-01",
      "mediaInfo" => %{
        "width" => 1920,
        "height" => 1080,
        "videoCodec" => "HEVC",
        "audioCodec" => "AAC",
        "audioChannels" => 2,
        "audioLanguages" => "English",
        "subtitles" => "",
        "videoDynamicRange" => nil,
        "videoDynamicRangeType" => nil,
        "videoBitrate" => 4000,
        "audioBitrate" => 192
      }
    }

    Map.merge(base, overrides)
  end

  describe "from_service_file/2" do
    test "returns a map with media.track structure for :sonarr" do
      result = MediaInfoConverter.from_service_file(minimal_service_file(), :sonarr)
      assert %{"media" => %{"track" => tracks}} = result
      assert length(tracks) == 3
    end

    test "returns a map with media.track structure for :radarr" do
      result = MediaInfoConverter.from_service_file(minimal_service_file(), :radarr)
      assert %{"media" => %{"track" => tracks}} = result
      assert length(tracks) == 3
    end

    test "General track includes file size" do
      %{"media" => %{"track" => tracks}} =
        MediaInfoConverter.from_service_file(minimal_service_file(), :sonarr)

      general = Enum.find(tracks, &(&1["@type"] == "General"))
      assert general["FileSize"] == 2_000_000
    end

    test "Video track includes correct resolution" do
      %{"media" => %{"track" => tracks}} =
        MediaInfoConverter.from_service_file(minimal_service_file(), :sonarr)

      video = Enum.find(tracks, &(&1["@type"] == "Video"))
      assert video["Width"] == 1920
      assert video["Height"] == 1080
    end

    test "uses overallBitrate when present" do
      %{"media" => %{"track" => tracks}} =
        MediaInfoConverter.from_service_file(minimal_service_file(), :sonarr)

      general = Enum.find(tracks, &(&1["@type"] == "General"))
      assert general["OverallBitRate"] == 5000
    end

    test "handles missing mediaInfo gracefully" do
      file = Map.delete(minimal_service_file(), "mediaInfo")
      result = MediaInfoConverter.from_service_file(file, :sonarr)
      assert %{"media" => %{"track" => [_, _, _]}} = result
    end
  end

  defp movie_service_file do
    %{
      "path" => "/media/movie.mkv",
      "size" => 5_000_000,
      "id" => 42,
      "runTime" => 7200,
      "overallBitrate" => 8000,
      "videoFps" => 24.0,
      "sceneName" => "Movie.2024",
      "dateAdded" => "2024-06-01",
      "year" => 2024,
      "mediaInfo" => %{
        "width" => 3840,
        "height" => 2160,
        "videoCodec" => "AVC",
        "audioCodec" => "DTS",
        "audioChannels" => 6,
        "audioLanguages" => "English",
        "subtitles" => "English/French"
      }
    }
  end

  describe "video_file_info_from_file/2" do
    test "returns a VideoFileInfo struct" do
      result =
        MediaInfoConverter.video_file_info_from_file(movie_service_file(), :radarr)

      assert %VideoFileInfo{} = result
    end

    test "sets path from file data" do
      result =
        MediaInfoConverter.video_file_info_from_file(movie_service_file(), :radarr)

      assert result.path == "/media/movie.mkv"
    end

    test "sets service_type" do
      result =
        MediaInfoConverter.video_file_info_from_file(movie_service_file(), :radarr)

      assert result.service_type == :radarr
    end

    test "sets service_id from id field" do
      result =
        MediaInfoConverter.video_file_info_from_file(movie_service_file(), :radarr)

      assert result.service_id == "42"
    end

    test "sets resolution as tuple from width/height" do
      result =
        MediaInfoConverter.video_file_info_from_file(movie_service_file(), :radarr)

      assert result.resolution == {3840, 2160}
    end

    test "sets audio_channels from mediaInfo" do
      result =
        MediaInfoConverter.video_file_info_from_file(movie_service_file(), :radarr)

      assert result.audio_channels == 6
    end

    test "handles missing mediaInfo" do
      file = Map.delete(movie_service_file(), "mediaInfo")

      result = MediaInfoConverter.video_file_info_from_file(file, :sonarr)
      assert %VideoFileInfo{} = result
      assert result.resolution == {0, 0}
    end
  end
end
