defmodule Reencodarr.Media.VideoValidatorTest do
  use ExUnit.Case, async: true
  alias Reencodarr.Media.VideoValidator

  describe "extract_comparison_values/1" do
    test "extracts values from string key attrs" do
      attrs = %{
        "size" => 1000,
        "bitrate" => 5000,
        "duration" => 3600.0,
        "video_codecs" => ["H.264"],
        "audio_codecs" => ["AAC"]
      }

      result = VideoValidator.extract_comparison_values(attrs)

      assert result == %{
               size: 1000,
               bitrate: 5000,
               duration: 3600.0,
               video_codecs: ["H.264"],
               audio_codecs: ["AAC"]
             }
    end

    test "extracts values from atom key attrs" do
      attrs = %{
        size: 1000,
        bitrate: 5000,
        duration: 3600.0,
        video_codecs: ["H.264"],
        audio_codecs: ["AAC"]
      }

      result = VideoValidator.extract_comparison_values(attrs)

      assert result == %{
               size: 1000,
               bitrate: 5000,
               duration: 3600.0,
               video_codecs: ["H.264"],
               audio_codecs: ["AAC"]
             }
    end

    test "handles missing values" do
      attrs = %{"size" => 1000}

      result = VideoValidator.extract_comparison_values(attrs)

      assert result == %{
               size: 1000,
               bitrate: nil,
               duration: nil,
               video_codecs: nil,
               audio_codecs: nil
             }
    end
  end

  describe "should_delete_vmafs?/2" do
    test "returns false for nil existing video" do
      new_values = %{
        size: 1000,
        bitrate: 5000,
        duration: nil,
        video_codecs: nil,
        audio_codecs: nil
      }

      assert VideoValidator.should_delete_vmafs?(nil, new_values) == false
    end

    test "returns true when size changes" do
      existing = %{
        size: 1000,
        bitrate: 5000,
        duration: 3600.0,
        video_codecs: ["H.264"],
        audio_codecs: ["AAC"]
      }

      new_values = %{
        size: 2000,
        bitrate: nil,
        duration: nil,
        video_codecs: nil,
        audio_codecs: nil
      }

      assert VideoValidator.should_delete_vmafs?(existing, new_values) == true
    end

    test "returns false when size unchanged and bitrate not explicitly zero" do
      existing = %{
        size: 1000,
        bitrate: 5000,
        duration: 3600.0,
        video_codecs: ["H.264"],
        audio_codecs: ["AAC"]
      }

      new_values = %{
        size: 1000,
        bitrate: 6000,
        duration: nil,
        video_codecs: nil,
        audio_codecs: nil
      }

      assert VideoValidator.should_delete_vmafs?(existing, new_values) == false
    end

    test "returns true when bitrate explicitly set to zero" do
      existing = %{
        size: 1000,
        bitrate: 5000,
        duration: 3600.0,
        video_codecs: ["H.264"],
        audio_codecs: ["AAC"]
      }

      new_values = %{size: 1000, bitrate: 0, duration: nil, video_codecs: nil, audio_codecs: nil}

      assert VideoValidator.should_delete_vmafs?(existing, new_values) == true
    end

    test "returns true when video codecs change" do
      existing = %{
        size: 1000,
        bitrate: 5000,
        duration: 3600.0,
        video_codecs: ["H.264"],
        audio_codecs: ["AAC"]
      }

      new_values = %{
        size: nil,
        bitrate: nil,
        duration: nil,
        video_codecs: ["H.265"],
        audio_codecs: nil
      }

      assert VideoValidator.should_delete_vmafs?(existing, new_values) == true
    end

    test "returns true when audio codecs change" do
      existing = %{
        size: 1000,
        bitrate: 5000,
        duration: 3600.0,
        video_codecs: ["H.264"],
        audio_codecs: ["AAC"]
      }

      new_values = %{
        size: nil,
        bitrate: nil,
        duration: nil,
        video_codecs: nil,
        audio_codecs: ["Opus"]
      }

      assert VideoValidator.should_delete_vmafs?(existing, new_values) == true
    end

    test "returns false when no significant changes" do
      existing = %{
        size: 1000,
        bitrate: 5000,
        duration: 3600.0,
        video_codecs: ["H.264"],
        audio_codecs: ["AAC"]
      }

      new_values = %{size: nil, bitrate: nil, duration: nil, video_codecs: nil, audio_codecs: nil}

      assert VideoValidator.should_delete_vmafs?(existing, new_values) == false
    end
  end

  describe "should_preserve_bitrate?/2" do
    test "returns false for nil existing video" do
      new_values = %{
        size: 1000,
        bitrate: 5000,
        duration: nil,
        video_codecs: nil,
        audio_codecs: nil
      }

      assert VideoValidator.should_preserve_bitrate?(nil, new_values) == false
    end

    test "returns true when size unchanged and has valid bitrate" do
      existing = %{
        size: 1000,
        bitrate: 5000,
        duration: 3600.0,
        video_codecs: ["H.264"],
        audio_codecs: ["AAC"]
      }

      new_values = %{
        size: 1000,
        bitrate: 6000,
        duration: nil,
        video_codecs: nil,
        audio_codecs: nil
      }

      assert VideoValidator.should_preserve_bitrate?(existing, new_values) == true
    end

    test "returns true when size is nil (not being updated) and has valid bitrate" do
      existing = %{
        size: 1000,
        bitrate: 5000,
        duration: 3600.0,
        video_codecs: ["H.264"],
        audio_codecs: ["AAC"]
      }

      new_values = %{
        size: nil,
        bitrate: 6000,
        duration: nil,
        video_codecs: nil,
        audio_codecs: nil
      }

      assert VideoValidator.should_preserve_bitrate?(existing, new_values) == true
    end

    test "returns false when size changes" do
      existing = %{
        size: 1000,
        bitrate: 5000,
        duration: 3600.0,
        video_codecs: ["H.264"],
        audio_codecs: ["AAC"]
      }

      new_values = %{
        size: 2000,
        bitrate: 6000,
        duration: nil,
        video_codecs: nil,
        audio_codecs: nil
      }

      assert VideoValidator.should_preserve_bitrate?(existing, new_values) == false
    end

    test "returns false when no existing bitrate" do
      existing = %{
        size: 1000,
        bitrate: nil,
        duration: 3600.0,
        video_codecs: ["H.264"],
        audio_codecs: ["AAC"]
      }

      new_values = %{
        size: 1000,
        bitrate: 6000,
        duration: nil,
        video_codecs: nil,
        audio_codecs: nil
      }

      assert VideoValidator.should_preserve_bitrate?(existing, new_values) == false
    end

    test "returns false when existing bitrate is zero" do
      existing = %{
        size: 1000,
        bitrate: 0,
        duration: 3600.0,
        video_codecs: ["H.264"],
        audio_codecs: ["AAC"]
      }

      new_values = %{
        size: 1000,
        bitrate: 6000,
        duration: nil,
        video_codecs: nil,
        audio_codecs: nil
      }

      assert VideoValidator.should_preserve_bitrate?(existing, new_values) == false
    end

    test "returns false when new bitrate is explicitly zero" do
      existing = %{
        size: 1000,
        bitrate: 5000,
        duration: 3600.0,
        video_codecs: ["H.264"],
        audio_codecs: ["AAC"]
      }

      new_values = %{size: 1000, bitrate: 0, duration: nil, video_codecs: nil, audio_codecs: nil}

      assert VideoValidator.should_preserve_bitrate?(existing, new_values) == false
    end
  end

  describe "get_attr_value/2" do
    test "gets value by string key" do
      attrs = %{"size" => 1000}
      assert VideoValidator.get_attr_value(attrs, "size") == 1000
    end

    test "gets value by atom key when string key missing" do
      attrs = %{size: 1000}
      assert VideoValidator.get_attr_value(attrs, "size") == 1000
    end

    test "prefers string key over atom key" do
      attrs = %{"size" => 1000, size: 2000}
      assert VideoValidator.get_attr_value(attrs, "size") == 1000
    end

    test "returns nil when key not found" do
      attrs = %{"other" => 1000}
      assert VideoValidator.get_attr_value(attrs, "size") == nil
    end
  end
end
