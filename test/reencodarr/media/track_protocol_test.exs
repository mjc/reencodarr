defmodule Reencodarr.Media.TrackProtocolTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Media.MediaInfo
  alias Reencodarr.Media.MediaInfo.{GeneralTrack, VideoTrack, AudioTrack, TextTrack}
  alias Reencodarr.Media.TrackProtocol

  describe "TrackProtocol" do
    test "identifies track types correctly" do
      general = %GeneralTrack{FileSize: 1000}
      video = %VideoTrack{Width: 1920, Height: 1080}
      audio = %AudioTrack{CodecID: "aac"}
      text = %TextTrack{Format: "srt"}

      assert TrackProtocol.track_type(general) == :general
      assert TrackProtocol.track_type(video) == :video
      assert TrackProtocol.track_type(audio) == :audio
      assert TrackProtocol.track_type(text) == :text
    end

    test "extracts metadata in normalized format" do
      video = %VideoTrack{
        Width: 1920,
        Height: 1080,
        FrameRate: 23.976,
        CodecID: "h264"
      }

      metadata = TrackProtocol.extract_metadata(video)

      assert metadata.width == 1920
      assert metadata.height == 1080
      assert metadata.frame_rate == 23.976
    end

    test "validates tracks properly" do
      valid_video = %VideoTrack{Width: 1920, Height: 1080}
      invalid_video = %VideoTrack{Width: nil, Height: nil}

      assert TrackProtocol.valid?(valid_video) == true
      assert TrackProtocol.valid?(invalid_video) == false
    end

    test "extracts codec IDs" do
      video = %VideoTrack{CodecID: "h264"}
      audio = %AudioTrack{CodecID: "aac"}

      assert TrackProtocol.codec_id(video) == "h264"
      assert TrackProtocol.codec_id(audio) == "aac"
    end

    test "converts to legacy map format" do
      video = %VideoTrack{
        Width: 1920,
        Height: 1080,
        CodecID: "h264"
      }

      legacy_map = TrackProtocol.to_legacy_map(video)

      assert legacy_map["@type"] == "Video"
      assert legacy_map[:Width] == 1920
      assert legacy_map[:Height] == 1080
      assert legacy_map[:CodecID] == "h264"
    end
  end

  describe "new track extraction functions" do
    test "extract_tracks_by_type works with protocol" do
      mediainfo_json = %{
        "media" => %{
          "track" => [
            %{"@type" => "General", "FileSize" => "1000000"},
            %{"@type" => "Video", "Width" => "1920", "Height" => "1080", "CodecID" => "h264"},
            %{"@type" => "Audio", "CodecID" => "aac"},
            %{"@type" => "Audio", "CodecID" => "eac3"}
          ]
        }
      }

      [media_info] = MediaInfo.from_json(mediainfo_json)

      video_tracks = MediaInfo.extract_tracks_by_type(media_info, :video)
      audio_tracks = MediaInfo.extract_tracks_by_type(media_info, :audio)
      general_track = MediaInfo.extract_first_track(media_info, :general)

      assert length(video_tracks) == 1
      assert length(audio_tracks) == 2
      assert %GeneralTrack{} = general_track
    end

    test "extract_codec_ids works with protocol" do
      mediainfo_json = %{
        "media" => %{
          "track" => [
            %{"@type" => "Video", "CodecID" => "h264"},
            %{"@type" => "Audio", "CodecID" => "aac"},
            %{"@type" => "Audio", "CodecID" => "eac3"}
          ]
        }
      }

      [media_info] = MediaInfo.from_json(mediainfo_json)

      video_codecs = MediaInfo.extract_codec_ids(media_info, :video)
      audio_codecs = MediaInfo.extract_codec_ids(media_info, :audio)

      assert video_codecs == ["h264"]
      assert audio_codecs == ["aac", "eac3"]
    end

    test "tracks_to_legacy_maps works with protocol" do
      general = %GeneralTrack{FileSize: 1000}
      video = %VideoTrack{Width: 1920, Height: 1080, CodecID: "h264"}
      audio = %AudioTrack{CodecID: "aac"}

      legacy_maps = MediaInfo.tracks_to_legacy_maps(general, [video], [audio])

      assert length(legacy_maps) == 3
      assert Enum.find(legacy_maps, &(&1["@type"] == "General"))
      assert Enum.find(legacy_maps, &(&1["@type"] == "Video"))
      assert Enum.find(legacy_maps, &(&1["@type"] == "Audio"))
    end
  end
end
