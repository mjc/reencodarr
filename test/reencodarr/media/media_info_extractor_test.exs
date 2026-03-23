defmodule Reencodarr.Media.MediaInfoExtractorTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Media.MediaInfoExtractor

  defp valid_mediainfo do
    %{
      "media" => %{
        "track" => [
          %{
            "@type" => "General",
            "Duration" => 3600.0,
            "FileSize" => 1_500_000_000,
            "OverallBitRate" => 5_000_000,
            "AudioCount" => 1,
            "VideoCount" => 1,
            "TextCount" => 0
          },
          %{
            "@type" => "Video",
            "CodecID" => "hvc1",
            "Width" => 1920,
            "Height" => 1080,
            "FrameRate" => "24.0"
          },
          %{
            "@type" => "Audio",
            "CodecID" => "AAC",
            "Channels" => "2"
          }
        ]
      }
    }
  end

  describe "extract_video_params/2" do
    test "returns a map for valid mediainfo" do
      result = MediaInfoExtractor.extract_video_params(valid_mediainfo(), "/media/show.mkv")
      assert is_map(result)
    end

    test "extracts width and height" do
      result = MediaInfoExtractor.extract_video_params(valid_mediainfo(), "/media/show.mkv")
      assert result.width == 1920
      assert result.height == 1080
    end

    test "extracts duration" do
      result = MediaInfoExtractor.extract_video_params(valid_mediainfo(), "/media/show.mkv")
      assert result.duration == 3600.0
    end

    test "extracts video codecs" do
      result = MediaInfoExtractor.extract_video_params(valid_mediainfo(), "/media/show.mkv")
      assert "hvc1" in result.video_codecs
    end

    test "extracts audio codecs" do
      result = MediaInfoExtractor.extract_video_params(valid_mediainfo(), "/media/show.mkv")
      assert "AAC" in result.audio_codecs
    end

    test "extracts audio channel count" do
      result = MediaInfoExtractor.extract_video_params(valid_mediainfo(), "/media/show.mkv")
      assert result.max_audio_channels >= 0
    end

    test "sets atmos to false for AAC audio" do
      result = MediaInfoExtractor.extract_video_params(valid_mediainfo(), "/media/show.mkv")
      refute result.atmos
    end

    test "returns {:error, reason} for zero width" do
      mediainfo =
        put_in(valid_mediainfo(), ["media", "track"], [
          %{"@type" => "General", "Duration" => 100.0, "FileSize" => 1000},
          %{"@type" => "Video", "CodecID" => "hvc1", "Width" => 0, "Height" => 1080}
        ])

      result = MediaInfoExtractor.extract_video_params(mediainfo, "/media/bad.mkv")
      assert {:error, _reason} = result
    end

    test "returns {:error, reason} for zero height" do
      mediainfo =
        put_in(valid_mediainfo(), ["media", "track"], [
          %{"@type" => "General", "Duration" => 100.0, "FileSize" => 1000},
          %{"@type" => "Video", "CodecID" => "hvc1", "Width" => 1920, "Height" => 0}
        ])

      result = MediaInfoExtractor.extract_video_params(mediainfo, "/media/bad.mkv")
      assert {:error, _reason} = result
    end

    test "returns {:error, reason} for nil mediainfo" do
      result = MediaInfoExtractor.extract_video_params(nil, "/media/show.mkv")
      assert {:error, _reason} = result
    end

    test "returns {:error, reason} for empty mediainfo" do
      result = MediaInfoExtractor.extract_video_params(%{}, "/media/show.mkv")
      assert {:error, _reason} = result
    end

    test "extracts HDR info when present" do
      mediainfo =
        update_in(valid_mediainfo(), ["media", "track"], fn tracks ->
          Enum.map(tracks, fn
            %{"@type" => "Video"} = v -> Map.put(v, "HDR_Format", "HDR10")
            t -> t
          end)
        end)

      result = MediaInfoExtractor.extract_video_params(mediainfo, "/media/hdr.mkv")
      assert is_map(result)
      assert result.hdr != nil
    end

    test "extracts 4K resolution" do
      mediainfo =
        update_in(valid_mediainfo(), ["media", "track"], fn tracks ->
          Enum.map(tracks, fn
            %{"@type" => "Video"} = v -> Map.merge(v, %{"Width" => 3840, "Height" => 2160})
            t -> t
          end)
        end)

      result = MediaInfoExtractor.extract_video_params(mediainfo, "/media/4k.mkv")
      assert result.width == 3840
      assert result.height == 2160
    end

    test "handles audio track with Atmos format" do
      mediainfo =
        update_in(valid_mediainfo(), ["media", "track"], fn tracks ->
          tracks ++
            [
              %{
                "@type" => "Audio",
                "CodecID" => "ec-3",
                "Format" => "E-AC-3",
                "Format_AdditionalFeatures" => "JOC / Atmos",
                "Channels" => "16"
              }
            ]
        end)

      result = MediaInfoExtractor.extract_video_params(mediainfo, "/media/atmos.mkv")
      assert is_map(result)
      assert result.atmos
    end

    test "detects Atmos from raw CodecID JOC markers" do
      mediainfo =
        update_in(valid_mediainfo(), ["media", "track"], fn tracks ->
          tracks ++
            [
              %{
                "@type" => "Audio",
                "CodecID" => "A_EAC3/JOC",
                "Format" => "AAC",
                "Channels" => "6"
              }
            ]
        end)

      result = MediaInfoExtractor.extract_video_params(mediainfo, "/media/joc.mkv")
      assert is_map(result)
      assert result.atmos
    end
  end
end
