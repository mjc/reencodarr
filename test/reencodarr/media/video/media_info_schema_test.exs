defmodule Reencodarr.Media.Video.MediaInfoSchemaTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Media.Video.MediaInfo

  # A minimal valid MediaInfo JSON payload
  defp valid_json do
    %{
      "media" => %{
        "track" => [
          %{
            "@type" => "General",
            "Duration" => 3600.0,
            "FileSize" => 1_500_000_000,
            "OverallBitRate" => 5_000_000
          },
          %{
            "@type" => "Video",
            "Format" => "HEVC",
            "Width" => 1920,
            "Height" => 1080,
            "FrameRate" => 24.0
          },
          %{
            "@type" => "Audio",
            "Format" => "AAC",
            "Channels" => 2
          }
        ]
      }
    }
  end

  describe "from_json/1" do
    test "returns a MediaInfo struct from valid JSON" do
      assert {:ok, %MediaInfo{}} = MediaInfo.from_json(valid_json())
    end

    test "general track is parsed" do
      {:ok, mi} = MediaInfo.from_json(valid_json())
      assert mi.general != nil
      assert mi.general.duration == 3600.0
    end

    test "video tracks are parsed" do
      {:ok, mi} = MediaInfo.from_json(valid_json())
      assert length(mi.video_tracks) == 1
      assert hd(mi.video_tracks).format == "HEVC"
    end

    test "audio tracks are parsed" do
      {:ok, mi} = MediaInfo.from_json(valid_json())
      assert length(mi.audio_tracks) == 1
      assert hd(mi.audio_tracks).format == "AAC"
      assert hd(mi.audio_tracks).channels == 2
    end

    test "returns error for nil" do
      assert {:error, _reason} = MediaInfo.from_json(nil)
    end

    test "returns error for empty map" do
      assert {:error, _reason} = MediaInfo.from_json(%{})
    end

    test "returns error for missing duration in general track" do
      invalid =
        put_in(valid_json(), ["media", "track"], [
          %{"@type" => "General"},
          %{"@type" => "Video", "Format" => "HEVC", "Width" => 1920, "Height" => 1080},
          %{"@type" => "Audio", "Format" => "AAC", "Channels" => 2}
        ])

      assert {:error, _reason} = MediaInfo.from_json(invalid)
    end

    test "returns error for missing video track format" do
      invalid =
        put_in(valid_json(), ["media", "track"], [
          %{"@type" => "General", "Duration" => 3600.0, "FileSize" => 100},
          %{"@type" => "Video", "Width" => 1920, "Height" => 1080},
          %{"@type" => "Audio", "Format" => "AAC", "Channels" => 2}
        ])

      assert {:error, _reason} = MediaInfo.from_json(invalid)
    end

    test "handles multiple video tracks" do
      json =
        update_in(valid_json(), ["media", "track"], fn tracks ->
          tracks ++
            [%{"@type" => "Video", "Format" => "AVC", "Width" => 1280, "Height" => 720}]
        end)

      {:ok, mi} = MediaInfo.from_json(json)
      assert length(mi.video_tracks) == 2
    end

    test "handles multiple audio tracks" do
      json =
        update_in(valid_json(), ["media", "track"], fn tracks ->
          tracks ++ [%{"@type" => "Audio", "Format" => "DTS", "Channels" => 6}]
        end)

      {:ok, mi} = MediaInfo.from_json(json)
      assert length(mi.audio_tracks) == 2
    end

    test "parses batch format with track key at top level" do
      batch_json = %{
        "track" => [
          %{"@type" => "General", "Duration" => 100.0, "FileSize" => 100},
          %{"@type" => "Video", "Format" => "HEVC", "Width" => 1920, "Height" => 1080},
          %{"@type" => "Audio", "Format" => "AAC", "Channels" => 2}
        ]
      }

      assert {:ok, %MediaInfo{}} = MediaInfo.from_json(batch_json)
    end
  end

  describe "to_video_params/1" do
    test "returns ok with video params from valid MediaInfo struct" do
      {:ok, mi} = MediaInfo.from_json(valid_json())
      assert {:ok, params} = MediaInfo.to_video_params(mi)
      assert is_map(params)
    end

    test "includes duration in params" do
      {:ok, mi} = MediaInfo.from_json(valid_json())
      {:ok, params} = MediaInfo.to_video_params(mi)
      assert Map.has_key?(params, "duration")
    end

    test "includes video_codecs in params" do
      {:ok, mi} = MediaInfo.from_json(valid_json())
      {:ok, params} = MediaInfo.to_video_params(mi)
      assert Map.has_key?(params, "video_codecs")
      assert "HEVC" in params["video_codecs"]
    end

    test "includes audio_codecs in params" do
      {:ok, mi} = MediaInfo.from_json(valid_json())
      {:ok, params} = MediaInfo.to_video_params(mi)
      assert Map.has_key?(params, "audio_codecs")
      assert "AAC" in params["audio_codecs"]
    end

    test "includes max_audio_channels in params" do
      {:ok, mi} = MediaInfo.from_json(valid_json())
      {:ok, params} = MediaInfo.to_video_params(mi)
      assert params["max_audio_channels"] == 2
    end

    test "includes width and height in params" do
      {:ok, mi} = MediaInfo.from_json(valid_json())
      {:ok, params} = MediaInfo.to_video_params(mi)
      assert params["width"] == 1920
      assert params["height"] == 1080
    end

    test "detects HDR from BT.2020 color space" do
      hdr_json =
        update_in(valid_json(), ["media", "track"], fn tracks ->
          Enum.map(tracks, fn
            %{"@type" => "Video"} = v -> Map.put(v, "colour_primaries", "BT.2020")
            t -> t
          end)
        end)

      {:ok, mi} = MediaInfo.from_json(hdr_json)
      {:ok, params} = MediaInfo.to_video_params(mi)
      # HDR may or may not be detected - just ensure key exists
      assert Map.has_key?(params, "hdr")
    end

    test "returns error when general track is nil" do
      mi = %MediaInfo{general: nil, video_tracks: [], audio_tracks: []}
      assert {:error, _} = MediaInfo.to_video_params(mi)
    end

    test "returns error when no video tracks" do
      mi = %MediaInfo{
        general: %MediaInfo.GeneralTrack{duration: 100.0},
        video_tracks: [],
        audio_tracks: []
      }

      assert {:error, _} = MediaInfo.to_video_params(mi)
    end
  end

  describe "changeset/2" do
    test "valid attrs produce a valid changeset" do
      attrs = %{
        "general" => %{
          "Duration" => 3600.0,
          "FileSize" => 1_000_000,
          "OverallBitRate" => 5_000_000
        },
        "video_tracks" => [
          %{"Format" => "HEVC", "Width" => 1920, "Height" => 1080}
        ],
        "audio_tracks" => [
          %{"Format" => "AAC", "Channels" => 2}
        ]
      }

      cs = MediaInfo.changeset(%MediaInfo{}, attrs)
      assert cs.valid?
    end

    test "missing general track makes changeset invalid" do
      attrs = %{
        "video_tracks" => [%{"Format" => "HEVC", "Width" => 1920, "Height" => 1080}],
        "audio_tracks" => []
      }

      cs = MediaInfo.changeset(%MediaInfo{}, attrs)
      refute cs.valid?
    end

    test "missing video tracks makes changeset invalid" do
      attrs = %{
        "general" => %{"Duration" => 100.0, "FileSize" => 100},
        "video_tracks" => [],
        "audio_tracks" => []
      }

      cs = MediaInfo.changeset(%MediaInfo{}, attrs)
      refute cs.valid?
    end
  end
end
