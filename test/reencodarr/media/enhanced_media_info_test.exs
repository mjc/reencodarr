defmodule Reencodarr.Media.EnhancedMediaInfoTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Media.EnhancedMediaInfo
  alias Reencodarr.Media.FieldTypes
  alias Reencodarr.Media.MediaInfo
  alias Reencodarr.Media.MediaInfo.{AudioTrack, GeneralTrack, TextTrack, VideoTrack}

  describe "parse_json/2 with strict mode" do
    test "parses valid MediaInfo JSON successfully" do
      valid_json = %{
        "creatingLibrary" => %{
          "name" => "MediaInfoLib",
          "version" => "21.09",
          "url" => "https://mediaarea.net/MediaInfo"
        },
        "media" => %{
          "@ref" => "test.mkv",
          "track" => [
            %{
              "@type" => "General",
              "FileSize" => "1000000000",
              "Duration" => "7200.0",
              "OverallBitRate" => "5000000",
              "VideoCount" => "1",
              "AudioCount" => "2"
            },
            %{
              "@type" => "Video",
              "Width" => "1920",
              "Height" => "1080",
              "FrameRate" => "23.976",
              "Format" => "AVC",
              "Duration" => "7200.0"
            },
            %{
              "@type" => "Audio",
              "Format" => "AAC",
              "Channels" => "2",
              "SamplingRate" => "48000",
              "Duration" => "7200.0"
            }
          ]
        }
      }

      assert {:ok, media_info} = EnhancedMediaInfo.parse_json(valid_json, :strict)
      assert %MediaInfo{} = media_info
      assert media_info.creatingLibrary.name == "MediaInfoLib"
      assert length(media_info.media.track) == 3
    end

    test "fails on invalid field values in strict mode" do
      invalid_json = %{
        "media" => %{
          "track" => [
            %{
              "@type" => "Video",
              # Invalid: below minimum
              "Width" => "0",
              "Height" => "1080",
              "FrameRate" => "23.976",
              "Format" => "AVC"
            }
          ]
        }
      }

      assert {:error, errors} = EnhancedMediaInfo.parse_json(invalid_json, :strict)
      assert length(errors) >= 1

      width_error =
        Enum.find(errors, fn
          {:validation_error, :Width, _} -> true
          _ -> false
        end)

      assert width_error != nil
    end

    test "handles missing required fields gracefully" do
      minimal_json = %{
        "media" => %{
          "track" => [
            %{
              "@type" => "General",
              "FileSize" => "1000000"
              # Missing other fields - should be ok
            }
          ]
        }
      }

      assert {:ok, media_info} = EnhancedMediaInfo.parse_json(minimal_json, :strict)
      assert length(media_info.media.track) == 1
    end
  end

  describe "parse_json/2 with lenient mode" do
    test "continues parsing despite validation errors" do
      invalid_json = %{
        "media" => %{
          "track" => [
            %{
              "@type" => "Video",
              # Invalid but should be kept in lenient mode
              "Width" => "0",
              "Height" => "1080",
              "Format" => "AVC"
            },
            %{
              "@type" => "Audio",
              "Format" => "AAC",
              "Channels" => "2"
            }
          ]
        }
      }

      assert {:ok, media_info} = EnhancedMediaInfo.parse_json(invalid_json, :lenient)
      assert length(media_info.media.track) == 2

      # Should have kept the invalid value in lenient mode
      video_track = Enum.find(media_info.media.track, &match?(%VideoTrack{}, &1))
      # In lenient mode, the string "0" should be converted to integer 0
      width_value = Map.get(video_track, :Width)
      assert width_value == 0 or width_value == "0"
    end

    test "handles completely malformed data" do
      malformed_json = %{
        "media" => %{
          "track" => [
            %{
              "@type" => "Video",
              "Width" => "not_a_number",
              # Array instead of number
              "Height" => [1, 2, 3],
              # Object instead of string
              "Format" => %{"nested" => "object"}
            }
          ]
        }
      }

      # Completely malformed data should fail even in lenient mode
      # when it can't be converted to strings
      assert {:error, _errors} = EnhancedMediaInfo.parse_json(malformed_json, :lenient)
    end
  end

  describe "to_video_params/1" do
    test "extracts correct Video schema parameters" do
      media_info = %MediaInfo{
        media: %MediaInfo.Media{
          track: [
            %GeneralTrack{
              FileSize: 1_000_000_000,
              Duration: 7200.0,
              OverallBitRate: 5_000_000,
              VideoCount: 1,
              AudioCount: 2,
              TextCount: 1,
              Title: "Test Movie"
            },
            %VideoTrack{
              Width: 1920,
              Height: 1080,
              FrameRate: 23.976,
              Format: "AVC",
              HDR_Format: nil
            },
            %AudioTrack{
              Format: "AAC",
              Channels: "2",
              SamplingRate: 48_000
            },
            %AudioTrack{
              Format: "AC-3",
              Channels: "6",
              SamplingRate: 48_000
            }
          ]
        }
      }

      assert {:ok, params} = EnhancedMediaInfo.to_video_params(media_info)

      assert params["width"] == 1920
      assert params["height"] == 1080
      assert params["duration"] == 7200.0
      assert params["size"] == 1_000_000_000
      assert params["video_count"] == 1
      assert params["audio_count"] == 2
      assert params["video_codecs"] == ["AVC"]
      assert params["audio_codecs"] == ["AAC", "AC-3"]
      assert params["max_audio_channels"] == 6
      assert params["atmos"] == false
      assert params["title"] == "Test Movie"
    end

    test "detects Atmos audio correctly" do
      media_info = %MediaInfo{
        media: %MediaInfo.Media{
          track: [
            %GeneralTrack{
              FileSize: 1_000_000_000,
              Duration: 7200.0,
              OverallBitRate: 5_000_000,
              VideoCount: 1,
              AudioCount: 1,
              TextCount: 0,
              Title: "Atmos Test"
            },
            %AudioTrack{
              Format: "E-AC-3 JOC (Dolby Digital Plus with Dolby Atmos)",
              Channels: "8"
            }
          ]
        }
      }

      assert {:ok, params} = EnhancedMediaInfo.to_video_params(media_info)
      assert params["atmos"] == true
    end

    test "handles missing tracks gracefully" do
      media_info = %MediaInfo{
        media: %MediaInfo.Media{
          track: [
            %GeneralTrack{
              FileSize: 1_000_000,
              Duration: 3600.0,
              OverallBitRate: 2_000_000,
              VideoCount: 0,
              AudioCount: 0,
              TextCount: 0,
              Title: "Minimal Test"
            }
            # No video or audio tracks
          ]
        }
      }

      assert {:ok, params} = EnhancedMediaInfo.to_video_params(media_info)
      assert params["size"] == 1_000_000
      assert params["duration"] == 3600.0
      assert params["video_codecs"] == []
      assert params["audio_codecs"] == []
      assert params["max_audio_channels"] == 0
      assert params["atmos"] == false
    end
  end

  describe "validate_tracks/2" do
    test "validates all tracks successfully" do
      tracks = [
        %GeneralTrack{
          FileSize: 1_000_000_000,
          Duration: 7200.0,
          VideoCount: 1
        },
        %VideoTrack{
          Width: 1920,
          Height: 1080,
          FrameRate: 23.976,
          Format: "AVC"
        }
      ]

      assert {:ok, validated_tracks} = EnhancedMediaInfo.validate_tracks(tracks, :strict)
      assert length(validated_tracks) == 2
    end

    test "returns errors in strict mode for invalid tracks" do
      tracks = [
        %VideoTrack{
          # Invalid
          Width: 0,
          Height: 1080,
          Format: "AVC"
        }
      ]

      assert {:error, errors} = EnhancedMediaInfo.validate_tracks(tracks, :strict)
      assert length(errors) >= 1
    end

    test "continues in lenient mode despite errors" do
      tracks = [
        %VideoTrack{
          # Invalid but should be kept
          Width: 0,
          Height: 1080,
          Format: "AVC"
        },
        %VideoTrack{
          # Valid
          Width: 1920,
          Height: 1080,
          Format: "HEVC"
        }
      ]

      assert {:ok, validated_tracks} = EnhancedMediaInfo.validate_tracks(tracks, :lenient)
      assert length(validated_tracks) == 2
    end
  end

  describe "conversion_report/2" do
    test "generates success report for valid data" do
      valid_json = %{
        "media" => %{
          "track" => [
            %{
              "@type" => "General",
              "FileSize" => "1000000"
            },
            %{
              "@type" => "Video",
              "Width" => "1920",
              "Height" => "1080"
            }
          ]
        }
      }

      report = EnhancedMediaInfo.conversion_report(valid_json, :strict)

      assert report.status == :success
      assert report.mode == :strict
      assert report.tracks_processed == 2
      assert report.validation_errors == []
      assert is_integer(report.processing_time_ms)
    end

    test "generates error report for invalid data" do
      invalid_json = %{
        "media" => %{
          "track" => [
            %{
              "@type" => "Video",
              # Invalid
              "Width" => "0",
              "Height" => "1080"
            }
          ]
        }
      }

      report = EnhancedMediaInfo.conversion_report(invalid_json, :strict)

      assert report.status == :error
      assert report.mode == :strict
      assert length(report.validation_errors) >= 1
      assert length(report.warnings) >= 1
    end

    test "includes processing time metrics" do
      json = %{"media" => %{"track" => []}}

      report = EnhancedMediaInfo.conversion_report(json, :lenient)

      assert is_integer(report.processing_time_ms)
      assert report.processing_time_ms >= 0
    end
  end

  describe "TextTrack type fixes" do
    test "properly converts TextTrack numeric fields" do
      json_with_text = %{
        "media" => %{
          "track" => [
            %{
              "@type" => "Text",
              "Format" => "UTF-8",
              # Should convert to float
              "Duration" => "7200.5",
              # Should convert to integer
              "BitRate" => "1000",
              # Should convert to float
              "FrameRate" => "25.0",
              # Should convert to integer
              "FrameCount" => "180000",
              # Should convert to integer
              "ElementCount" => "1500",
              # Should convert to integer
              "StreamSize" => "50000"
            }
          ]
        }
      }

      assert {:ok, media_info} = EnhancedMediaInfo.parse_json(json_with_text, :strict)

      text_track = Enum.find(media_info.media.track, &match?(%TextTrack{}, &1))
      assert text_track != nil

      # Verify proper type conversion
      assert is_float(Map.get(text_track, :Duration))
      assert Map.get(text_track, :Duration) == 7200.5

      assert is_integer(Map.get(text_track, :BitRate))
      assert Map.get(text_track, :BitRate) == 1000

      assert is_float(Map.get(text_track, :FrameRate))
      assert Map.get(text_track, :FrameRate) == 25.0

      assert is_integer(Map.get(text_track, :FrameCount))
      assert Map.get(text_track, :FrameCount) == 180_000
    end

    test "validates TextTrack field constraints" do
      json_with_invalid_text = %{
        "media" => %{
          "track" => [
            %{
              "@type" => "Text",
              # Invalid: negative duration
              "Duration" => "-100.0",
              # Invalid: negative bitrate
              "BitRate" => "-500",
              # Invalid: exceeds maximum
              "FrameRate" => "200.0"
            }
          ]
        }
      }

      assert {:error, errors} = EnhancedMediaInfo.parse_json(json_with_invalid_text, :strict)
      # Should have errors for all three fields
      assert length(errors) >= 3
    end
  end

  describe "Video schema field coverage" do
    test "handles all Video schema fields" do
      # Test that our FieldTypes system covers all fields used in Video changeset
      # Using PascalCase for MediaInfo fields and snake_case for Video schema fields
      mediainfo_fields = [
        :Width,
        :Height,
        :Duration,
        :FrameRate,
        :OverallBitRate,
        :FileSize,
        :VideoCount,
        :AudioCount,
        :TextCount,
        :Title
      ]

      video_schema_fields = [
        :max_audio_channels,
        :video_codecs,
        :audio_codecs,
        :hdr,
        :atmos,
        :reencoded,
        :failed,
        :service_id,
        :service_type,
        :path
      ]

      # Check MediaInfo fields (should be in general or video track types)
      Enum.each(mediainfo_fields, fn field ->
        covered =
          FieldTypes.get_field_type(:general, field) ||
            FieldTypes.get_field_type(:video, field) ||
            FieldTypes.get_field_type(:audio, field) ||
            FieldTypes.get_field_type(:text, field)

        assert covered != nil, "MediaInfo field #{field} is not covered by FieldTypes system"
      end)

      # Check Video schema specific fields
      Enum.each(video_schema_fields, fn field ->
        covered = FieldTypes.get_field_type(:video_schema, field)
        # Some fields like :reencoded, :failed are optional and may not be defined yet
        # Just check that the essential ones are covered
        if field in [:video_codecs, :audio_codecs, :max_audio_channels, :hdr, :atmos] do
          assert covered != nil, "Video schema field #{field} is not covered by FieldTypes system"
        end
      end)

      # Verify overall coverage is reasonable
      all_mediainfo_covered =
        Enum.all?(mediainfo_fields, fn field ->
          FieldTypes.get_field_type(:general, field) ||
            FieldTypes.get_field_type(:video, field) ||
            FieldTypes.get_field_type(:audio, field) ||
            FieldTypes.get_field_type(:text, field)
        end)

      assert all_mediainfo_covered, "Not all essential MediaInfo fields are covered"
    end
  end
end
