defmodule Reencodarr.AnalyzerTest do
  use Reencodarr.DataCase

  # Test Broadway modules directly since compatibility layer is removed
  alias Reencodarr.Analyzer.Broadway

  describe "Broadway analyzer API" do
    test "Broadway running status can be checked" do
      # Should not crash even when Broadway is not running in test
      result = Broadway.running?()
      assert is_boolean(result)
    end

    test "Broadway dispatch_available doesn't crash" do
      # Should handle missing producer gracefully
      case Broadway.dispatch_available() do
        :ok -> :ok
        {:error, :producer_supervisor_not_found} -> :ok
        {:error, :producer_not_found} -> :ok
        other -> flunk("Unexpected result: #{inspect(other)}")
      end
    end
  end

  describe "has_av1_codec?/1" do
    test "returns true when video_codecs contains av1" do
      assert Broadway.has_av1_codec?(%{video_codecs: ["V_AV1"]}) == true
    end

    test "returns true when video_codecs contains AV1" do
      assert Broadway.has_av1_codec?(%{video_codecs: ["AV1"]}) == true
    end

    test "returns false when video_codecs does not contain av1" do
      assert Broadway.has_av1_codec?(%{video_codecs: ["h264", "hevc"]}) == false
    end

    test "returns false when video_codecs is nil" do
      assert Broadway.has_av1_codec?(%{video_codecs: nil}) == false
    end

    test "returns false for struct without video_codecs key" do
      assert Broadway.has_av1_codec?(%{}) == false
    end
  end

  describe "has_av1_in_filename?/1" do
    test "returns true when filename contains av1" do
      assert Broadway.has_av1_in_filename?(%{path: "/media/video.av1.mkv"}) == true
    end

    test "returns true when filename contains AV1 (uppercase)" do
      assert Broadway.has_av1_in_filename?(%{path: "/media/video.AV1.mkv"}) == true
    end

    test "returns false when filename does not contain av1" do
      assert Broadway.has_av1_in_filename?(%{path: "/media/video.h264.mkv"}) == false
    end
  end

  describe "has_opus_codec?/1" do
    test "returns true when audio_codecs contains opus" do
      assert Broadway.has_opus_codec?(%{audio_codecs: ["opus"]}) == true
    end

    test "returns false when audio_codecs does not contain opus" do
      assert Broadway.has_opus_codec?(%{audio_codecs: ["aac", "ac3"]}) == false
    end

    test "returns false for non-list audio_codecs" do
      assert Broadway.has_opus_codec?(%{audio_codecs: nil}) == false
    end
  end

  describe "has_opus_in_filename?/1" do
    test "returns true when filename contains opus" do
      assert Broadway.has_opus_in_filename?(%{path: "/media/video.opus.mkv"}) == true
    end

    test "returns false when filename does not contain opus" do
      assert Broadway.has_opus_in_filename?(%{path: "/media/video.aac.mkv"}) == false
    end
  end
end
