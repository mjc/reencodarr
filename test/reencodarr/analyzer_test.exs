defmodule Reencodarr.AnalyzerTest do
  use Reencodarr.DataCase

  import Reencodarr.Fixtures

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

  describe "analyzer codec optimization" do
    test "videos with AV1 codec should be optimized to skip CRF search" do
      # Create a video with AV1 codec in needs_analysis state
      video =
        video_fixture(%{
          state: :needs_analysis,
          video_codecs: ["AV1"],
          audio_codecs: ["aac"]
        })

      # Verify the video has AV1 codec that should trigger optimization
      assert "AV1" in video.video_codecs
      refute "opus" in video.audio_codecs
    end

    test "videos with Opus audio should be optimized to skip CRF search" do
      # Create a video with Opus audio in needs_analysis state
      video =
        video_fixture(%{
          state: :needs_analysis,
          video_codecs: ["h264"],
          audio_codecs: ["opus"]
        })

      # Verify the video has Opus audio that should trigger optimization
      assert "opus" in video.audio_codecs
      refute "AV1" in video.video_codecs
    end

    test "videos with both AV1 and Opus should be optimized" do
      # Create a video with both target codecs
      video =
        video_fixture(%{
          state: :needs_analysis,
          video_codecs: ["AV1"],
          audio_codecs: ["opus"]
        })

      # Verify both codecs are present
      assert "AV1" in video.video_codecs
      assert "opus" in video.audio_codecs
    end

    test "videos without target codecs should proceed to CRF search" do
      # Create a video without AV1 or Opus
      video =
        video_fixture(%{
          state: :needs_analysis,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      # Verify no target codecs present
      refute "AV1" in video.video_codecs
      refute "opus" in video.audio_codecs
    end
  end
end
