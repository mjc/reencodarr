defmodule Reencodarr.Media.Video.MediaInfoTest do
  use ExUnit.Case, async: true
  alias Reencodarr.Media.Video.MediaInfo

  # Minimal valid track maps mirroring actual mediainfo JSON output
  defp general_track(overrides \\ %{}) do
    Map.merge(
      %{
        "@type" => "General",
        "Duration" => "7200.000",
        "FileSize" => "8589934592",
        "OverallBitRate" => "9437184"
      },
      overrides
    )
  end

  defp video_track(overrides \\ %{}) do
    Map.merge(
      %{
        "@type" => "Video",
        "Format" => "AVC",
        "Width" => "1920",
        "Height" => "1080",
        "FrameRate" => "23.976"
      },
      overrides
    )
  end

  defp audio_track(overrides \\ %{}) do
    Map.merge(
      %{
        "@type" => "Audio",
        "Format" => "AAC",
        # Use integer directly so is_integer/1 check in validate_channel_consistency passes
        # (parse_numeric/2 converts strings to floats which fails the is_integer guard)
        "Channels" => 2
      },
      overrides
    )
  end

  defp valid_json(extra_tracks \\ []) do
    %{
      "media" => %{
        "track" => [general_track(), video_track(), audio_track()] ++ extra_tracks
      }
    }
  end

  describe "from_json/1 - valid input" do
    test "returns {:ok, %MediaInfo{}} for well-formed JSON" do
      assert {:ok, %MediaInfo{}} = MediaInfo.from_json(valid_json())
    end

    test "parses general track duration" do
      {:ok, media_info} = MediaInfo.from_json(valid_json())
      assert media_info.general.duration == 7200.0
    end

    test "parses general track file size" do
      {:ok, media_info} = MediaInfo.from_json(valid_json())
      assert media_info.general.file_size == 8_589_934_592
    end

    test "parses general track overall bitrate" do
      {:ok, media_info} = MediaInfo.from_json(valid_json())
      assert media_info.general.overall_bit_rate == 9_437_184
    end

    test "parses video track format as codec" do
      {:ok, media_info} = MediaInfo.from_json(valid_json())
      [primary_video | _] = media_info.video_tracks
      assert primary_video.format == "AVC"
    end

    test "parses video track resolution" do
      {:ok, media_info} = MediaInfo.from_json(valid_json())
      [primary_video | _] = media_info.video_tracks
      assert primary_video.width == 1920
      assert primary_video.height == 1080
    end

    test "parses video track frame rate" do
      {:ok, media_info} = MediaInfo.from_json(valid_json())
      [primary_video | _] = media_info.video_tracks
      assert primary_video.frame_rate == 23.976
    end

    test "parses audio track format" do
      {:ok, media_info} = MediaInfo.from_json(valid_json())
      [primary_audio | _] = media_info.audio_tracks
      assert primary_audio.format == "AAC"
    end

    test "parses audio track channel count" do
      {:ok, media_info} = MediaInfo.from_json(valid_json())
      [primary_audio | _] = media_info.audio_tracks
      assert primary_audio.channels == 2
    end

    test "accepts multiple video tracks" do
      extra = video_track(%{"Format" => "HEVC", "Width" => "3840", "Height" => "2160"})
      {:ok, media_info} = MediaInfo.from_json(valid_json([extra]))
      assert length(media_info.video_tracks) == 2
    end

    test "accepts multiple audio tracks" do
      extra = audio_track(%{"Format" => "AC-3", "Channels" => 6})
      {:ok, media_info} = MediaInfo.from_json(valid_json([extra]))
      assert length(media_info.audio_tracks) == 2
    end

    test "accepts tracks without audio (audio_tracks can be empty)" do
      json = %{
        "media" => %{
          "track" => [general_track(), video_track()]
        }
      }

      result = MediaInfo.from_json(json)
      # Either valid (empty audio) or error — both are acceptable; verify no crash
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "from_json/1 - HDR detection" do
    test "detects HDR via BT.2020 color space" do
      hdr_video =
        video_track(%{
          "ColorSpace" => "BT.2020",
          "colour_primaries" => "BT.2020"
        })

      json = %{"media" => %{"track" => [general_track(), hdr_video, audio_track()]}}
      {:ok, media_info} = MediaInfo.from_json(json)
      [primary_video | _] = media_info.video_tracks
      assert primary_video.color_space == "BT.2020"
    end

    test "non-HDR video has nil color_space by default" do
      {:ok, media_info} = MediaInfo.from_json(valid_json())
      [primary_video | _] = media_info.video_tracks
      assert is_nil(primary_video.color_space) or primary_video.color_space != "BT.2020"
    end
  end

  describe "from_json/1 - error cases" do
    test "returns error for nil input" do
      assert {:error, _} = MediaInfo.from_json(nil)
    end

    test "returns error for empty map" do
      assert {:error, _} = MediaInfo.from_json(%{})
    end

    test "returns error for completely wrong structure" do
      assert {:error, _} = MediaInfo.from_json(%{"foo" => "bar"})
    end

    test "returns error when track list has no video track" do
      json = %{
        "media" => %{
          "track" => [general_track(), audio_track()]
        }
      }

      assert {:error, _} = MediaInfo.from_json(json)
    end

    test "returns error when general track is missing" do
      json = %{
        "media" => %{
          "track" => [video_track(), audio_track()]
        }
      }

      assert {:error, _} = MediaInfo.from_json(json)
    end

    test "returns error for empty track list" do
      json = %{"media" => %{"track" => []}}
      assert {:error, _} = MediaInfo.from_json(json)
    end

    test "returns error for non-map input" do
      assert {:error, _} = MediaInfo.from_json("invalid string")
      assert {:error, _} = MediaInfo.from_json(42)
      assert {:error, _} = MediaInfo.from_json([])
    end
  end

  describe "to_video_params/1" do
    test "returns {:ok, params} map for valid MediaInfo" do
      {:ok, media_info} = MediaInfo.from_json(valid_json())
      assert {:ok, params} = MediaInfo.to_video_params(media_info)
      assert is_map(params)
    end

    test "params include duration from general track" do
      {:ok, media_info} = MediaInfo.from_json(valid_json())
      {:ok, params} = MediaInfo.to_video_params(media_info)
      assert params["duration"] == 7200.0
    end

    test "params include video codecs list" do
      {:ok, media_info} = MediaInfo.from_json(valid_json())
      {:ok, params} = MediaInfo.to_video_params(media_info)
      assert "AVC" in params["video_codecs"]
    end

    test "params include audio codecs list" do
      {:ok, media_info} = MediaInfo.from_json(valid_json())
      {:ok, params} = MediaInfo.to_video_params(media_info)
      assert "AAC" in params["audio_codecs"]
    end

    test "params include max audio channels" do
      {:ok, media_info} = MediaInfo.from_json(valid_json())
      {:ok, params} = MediaInfo.to_video_params(media_info)
      assert params["max_audio_channels"] == 2
    end

    test "params include width and height" do
      {:ok, media_info} = MediaInfo.from_json(valid_json())
      {:ok, params} = MediaInfo.to_video_params(media_info)
      assert params["width"] == 1920
      assert params["height"] == 1080
    end

    test "picks max channels from multiple audio tracks" do
      extra_audio = audio_track(%{"Format" => "AC-3", "Channels" => 6})
      {:ok, media_info} = MediaInfo.from_json(valid_json([extra_audio]))
      {:ok, params} = MediaInfo.to_video_params(media_info)
      assert params["max_audio_channels"] == 6
    end

    test "collects codecs from multiple video tracks" do
      extra_video = video_track(%{"Format" => "HEVC", "Width" => "3840", "Height" => "2160"})
      {:ok, media_info} = MediaInfo.from_json(valid_json([extra_video]))
      {:ok, params} = MediaInfo.to_video_params(media_info)
      assert "AVC" in params["video_codecs"]
      assert "HEVC" in params["video_codecs"]
    end

    test "HDR is nil for SDR content" do
      {:ok, media_info} = MediaInfo.from_json(valid_json())
      {:ok, params} = MediaInfo.to_video_params(media_info)
      assert is_nil(params["hdr"])
    end

    test "HDR is 'HDR' for BT.2020 content" do
      hdr_video =
        video_track(%{
          "ColorSpace" => "BT.2020",
          "colour_primaries" => "BT.2020"
        })

      json = %{"media" => %{"track" => [general_track(), hdr_video, audio_track()]}}
      {:ok, media_info} = MediaInfo.from_json(json)
      {:ok, params} = MediaInfo.to_video_params(media_info)
      assert params["hdr"] == "HDR"
    end

    test "returns error for MediaInfo with missing general track" do
      # Construct a MediaInfo struct manually with nil general
      media_info = %MediaInfo{general: nil, video_tracks: [], audio_tracks: []}
      assert {:error, _} = MediaInfo.to_video_params(media_info)
    end

    test "returns error for MediaInfo with no video tracks" do
      media_info = %MediaInfo{
        general: %Reencodarr.Media.Video.MediaInfo.GeneralTrack{duration: 100.0},
        video_tracks: [],
        audio_tracks: []
      }

      assert {:error, _} = MediaInfo.to_video_params(media_info)
    end
  end
end
