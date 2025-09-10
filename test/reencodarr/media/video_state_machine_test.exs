defmodule Reencodarr.Media.VideoStateMachineTest do
  use Reencodarr.DataCase

  alias Reencodarr.Media.VideoStateMachine

  describe "transition_to_analyzed/2" do
    test "can transition to analyzed state without duration" do
      # Create a video without duration
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/no_duration_video.mkv",
          size: 1_000_000_000,
          bitrate: 5000,
          width: 1920,
          height: 1080,
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          max_audio_channels: 2,
          atmos: false,
          state: :needs_analysis
          # Note: duration is nil/missing
        })

      # Attempt to transition to analyzed state
      {:ok, changeset} = VideoStateMachine.transition_to_analyzed(video)

      # The changeset should be valid even without duration
      assert changeset.valid?,
             "Changeset should be valid without duration, errors: #{inspect(changeset.errors)}"

      # Apply the changeset
      {:ok, updated_video} = Repo.update(changeset)
      assert updated_video.state == :analyzed
    end

    test "can transition to analyzed state with valid duration" do
      # Create a video with duration
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/with_duration_video.mkv",
          size: 1_000_000_000,
          bitrate: 5000,
          width: 1920,
          height: 1080,
          duration: 7200.0,
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          max_audio_channels: 2,
          atmos: false,
          state: :needs_analysis
        })

      # Attempt to transition to analyzed state
      {:ok, changeset} = VideoStateMachine.transition_to_analyzed(video)

      # The changeset should be valid with duration
      assert changeset.valid?,
             "Changeset should be valid with duration, errors: #{inspect(changeset.errors)}"

      # Apply the changeset
      {:ok, updated_video} = Repo.update(changeset)
      assert updated_video.state == :analyzed
    end

    test "rejects invalid duration when present" do
      # Create a video
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/invalid_duration_video.mkv",
          size: 1_000_000_000,
          bitrate: 5000,
          width: 1920,
          height: 1080,
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          max_audio_channels: 2,
          atmos: false,
          state: :needs_analysis
        })

      # Try to transition with invalid duration
      {:ok, changeset} = VideoStateMachine.transition_to_analyzed(video, %{duration: -1.0})

      # The changeset should be invalid with negative duration
      refute changeset.valid?, "Changeset should be invalid with negative duration"
      assert changeset.errors[:duration], "Should have duration error"
    end

    test "rejects zero duration when present" do
      # Create a video
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/zero_duration_video.mkv",
          size: 1_000_000_000,
          bitrate: 5000,
          width: 1920,
          height: 1080,
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          max_audio_channels: 2,
          atmos: false,
          state: :needs_analysis
        })

      # Try to transition with zero duration
      {:ok, changeset} = VideoStateMachine.transition_to_analyzed(video, %{duration: 0.0})

      # The changeset should be invalid with zero duration
      refute changeset.valid?, "Changeset should be invalid with zero duration"
      assert changeset.errors[:duration], "Should have duration error"
    end

    test "requires bitrate, width, height for analyzed state" do
      # Create a video missing required fields
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/missing_required_video.mkv",
          size: 1_000_000_000,
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          max_audio_channels: 2,
          atmos: false,
          state: :needs_analysis,
          # Explicitly set these to nil to test validation
          bitrate: nil,
          width: nil,
          height: nil
        })

      # Try to transition without required fields
      {:ok, changeset} = VideoStateMachine.transition_to_analyzed(video)

      # The changeset should be invalid
      refute changeset.valid?, "Changeset should be invalid without required fields"

      # Check that it fails on the required fields
      required_errors = changeset.errors |> Keyword.keys()

      assert :bitrate in required_errors or :width in required_errors or
               :height in required_errors,
             "Should have errors for required fields, got: #{inspect(changeset.errors)}"
    end
  end
end
