defmodule Reencodarr.Media.Video.MediaInfo.TracksTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Media.Video.MediaInfo.{GeneralTrack, VideoTrack}

  describe "GeneralTrack.changeset/2" do
    test "valid attrs produce a valid changeset" do
      attrs = %{"Duration" => 3600.0, "FileSize" => 1_500_000_000, "OverallBitRate" => 5_000_000}
      cs = GeneralTrack.changeset(%GeneralTrack{}, attrs)
      assert cs.valid?
    end

    test "duration as integer is accepted" do
      attrs = %{"Duration" => 5400, "FileSize" => 1_000_000}
      cs = GeneralTrack.changeset(%GeneralTrack{}, attrs)
      assert cs.valid?
    end

    test "missing duration makes changeset invalid" do
      attrs = %{"FileSize" => 1_000_000}
      cs = GeneralTrack.changeset(%GeneralTrack{}, attrs)
      refute cs.valid?
    end

    test "duration can be a string '5400'" do
      attrs = %{"Duration" => "5400"}
      cs = GeneralTrack.changeset(%GeneralTrack{}, attrs)
      assert cs.valid?
    end

    test "file_size is optional" do
      attrs = %{"Duration" => 3600.0}
      cs = GeneralTrack.changeset(%GeneralTrack{}, attrs)
      assert cs.valid?
    end

    test "all fields are parsed from MediaInfo-style keys" do
      attrs = %{
        "Duration" => 3600.0,
        "FileSize" => 1_000_000_000,
        "OverallBitRate" => 10_000_000,
        "Format" => "Matroska",
        "Format_Profile" => "Version 4 / Version 2"
      }

      cs = GeneralTrack.changeset(%GeneralTrack{}, attrs)
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :format) == "Matroska"
    end

    test "snake_case keys are also accepted" do
      attrs = %{"duration" => 100.0, "file_size" => 500_000}
      cs = GeneralTrack.changeset(%GeneralTrack{}, attrs)
      assert cs.valid?
    end
  end

  defp valid_video_attrs do
    %{
      "Format" => "HEVC",
      "Width" => 1920,
      "Height" => 1080
    }
  end

  describe "VideoTrack.changeset/2" do
    test "valid attrs produce a valid changeset" do
      cs = VideoTrack.changeset(%VideoTrack{}, valid_video_attrs())
      assert cs.valid?
    end

    test "missing Format makes changeset invalid" do
      attrs = %{"Width" => 1920, "Height" => 1080}
      cs = VideoTrack.changeset(%VideoTrack{}, attrs)
      refute cs.valid?
    end

    test "missing Width makes changeset invalid" do
      attrs = %{"Format" => "HEVC", "Height" => 1080}
      cs = VideoTrack.changeset(%VideoTrack{}, attrs)
      refute cs.valid?
    end

    test "missing Height makes changeset invalid" do
      attrs = %{"Format" => "HEVC", "Width" => 1920}
      cs = VideoTrack.changeset(%VideoTrack{}, attrs)
      refute cs.valid?
    end

    test "width of 0 makes changeset invalid" do
      attrs = Map.put(valid_video_attrs(), "Width", 0)
      cs = VideoTrack.changeset(%VideoTrack{}, attrs)
      refute cs.valid?
    end

    test "height of 0 makes changeset invalid" do
      attrs = Map.put(valid_video_attrs(), "Height", 0)
      cs = VideoTrack.changeset(%VideoTrack{}, attrs)
      refute cs.valid?
    end

    test "FrameRate is parsed as float" do
      attrs = Map.put(valid_video_attrs(), "FrameRate", 23.976)
      cs = VideoTrack.changeset(%VideoTrack{}, attrs)
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :frame_rate) == 23.976
    end

    test "HdrFormat is parsed to hdr_format field" do
      attrs = Map.put(valid_video_attrs(), "HDR_Format", "Dolby Vision")
      cs = VideoTrack.changeset(%VideoTrack{}, attrs)
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :hdr_format) == "Dolby Vision"
    end

    test "colour_primaries is mapped to color_primaries" do
      attrs = Map.put(valid_video_attrs(), "colour_primaries", "BT.2020")
      cs = VideoTrack.changeset(%VideoTrack{}, attrs)
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :color_primaries) == "BT.2020"
    end

    test "lowercase format keys are also accepted" do
      attrs = %{"format" => "AVC", "width" => 1280, "height" => 720}
      cs = VideoTrack.changeset(%VideoTrack{}, attrs)
      assert cs.valid?
    end

    test "4K resolution is accepted" do
      attrs = %{"Format" => "HEVC", "Width" => 3840, "Height" => 2160}
      cs = VideoTrack.changeset(%VideoTrack{}, attrs)
      assert cs.valid?
    end
  end
end
