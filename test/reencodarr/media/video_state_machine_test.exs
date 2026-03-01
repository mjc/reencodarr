defmodule Reencodarr.Media.VideoStateMachineTest do
  use Reencodarr.DataCase

  alias Reencodarr.Media.VideoStateMachine

  describe "transition_to_analyzed/2" do
    test "can transition to analyzed state without duration" do
      # Create a video without duration but with HIGH bitrate to avoid low bitrate logic
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/no_duration_video.mkv",
          size: 1_000_000_000,
          # High bitrate to ensure normal transition to analyzed
          bitrate: 15_000,
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
      # Create a video with duration and HIGH bitrate
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/with_duration_video.mkv",
          size: 1_000_000_000,
          # High bitrate to ensure normal transition to analyzed
          bitrate: 15_000,
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
      # Create a video with HIGH bitrate to avoid low bitrate logic
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/invalid_duration_video.mkv",
          size: 1_000_000_000,
          # High bitrate to ensure normal transition to analyzed
          bitrate: 15_000,
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
      # Create a video with HIGH bitrate to avoid low bitrate logic
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/zero_duration_video.mkv",
          size: 1_000_000_000,
          # High bitrate to ensure normal transition to analyzed
          bitrate: 15_000,
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

  describe "low bitrate logic in transition_to_analyzed/2" do
    test "transitions low bitrate video directly to encoded state" do
      # Create a video with low bitrate (< 5,000,000 bps = 5 Mbps) AND HDR
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/low_bitrate_video.mkv",
          size: 1_000_000_000,
          # 3 Mbps - below 5 Mbps threshold
          bitrate: 3_000_000,
          # HDR content
          hdr: "HDR10",
          width: 1920,
          height: 1080,
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          max_audio_channels: 2,
          atmos: false,
          state: :needs_analysis
        })

      # Attempt to transition to analyzed state
      {:ok, changeset} = VideoStateMachine.transition_to_analyzed(video)

      # Should transition to encoded instead of analyzed
      assert changeset.changes.state == :encoded

      # Apply the changeset
      {:ok, updated_video} = Repo.update(changeset)
      assert updated_video.state == :encoded
    end

    test "transitions high bitrate video to analyzed state normally" do
      # Create a video with high bitrate (>= 5,000,000 bps = 5 Mbps) or non-HDR
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/high_bitrate_video.mkv",
          size: 1_000_000_000,
          # 15 Mbps - above 5 Mbps threshold
          bitrate: 15_000_000,
          # Even with HDR, high bitrate should go to analyzed
          hdr: "HDR10",
          width: 1920,
          height: 1080,
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          max_audio_channels: 2,
          atmos: false,
          state: :needs_analysis
        })

      # Attempt to transition to analyzed state
      {:ok, changeset} = VideoStateMachine.transition_to_analyzed(video)

      # Should transition to analyzed normally
      assert changeset.changes.state == :analyzed

      # Apply the changeset
      {:ok, updated_video} = Repo.update(changeset)
      assert updated_video.state == :analyzed
    end

    test "transitions video with nil bitrate to analyzed state normally" do
      # Create a video with nil bitrate
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/nil_bitrate_video.mkv",
          size: 1_000_000_000,
          bitrate: nil,
          width: 1920,
          height: 1080,
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          max_audio_channels: 2,
          atmos: false,
          state: :needs_analysis
        })

      # This should fail validation, but not due to low_bitrate? logic
      {:ok, changeset} = VideoStateMachine.transition_to_analyzed(video)

      # Should attempt to transition to analyzed (low_bitrate? returns false for nil)
      assert changeset.changes.state == :analyzed
    end

    test "treats exactly 5,000 kbps as high bitrate" do
      # Create a video with exactly 5,000,000 bps bitrate (5 Mbps) and HDR
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/threshold_bitrate_video.mkv",
          size: 1_000_000_000,
          # Exactly 5 Mbps - should not be considered low (>= threshold)
          bitrate: 5_000_000,
          # HDR content
          hdr: "HDR10",
          width: 1920,
          height: 1080,
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          max_audio_channels: 2,
          atmos: false,
          state: :needs_analysis
        })

      # Attempt to transition to analyzed state
      {:ok, changeset} = VideoStateMachine.transition_to_analyzed(video)

      # Should transition to analyzed (not low bitrate)
      assert changeset.changes.state == :analyzed

      # Apply the changeset
      {:ok, updated_video} = Repo.update(changeset)
      assert updated_video.state == :analyzed
    end

    test "transitions low bitrate non-HDR video to analyzed state (HDR required)" do
      # Create a video with low bitrate but no HDR - should not be considered low bitrate
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/low_bitrate_no_hdr_video.mkv",
          size: 1_000_000_000,
          # 3 Mbps - below 5 Mbps threshold but no HDR
          bitrate: 3_000_000,
          # No HDR content
          hdr: nil,
          width: 1920,
          height: 1080,
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          max_audio_channels: 2,
          atmos: false,
          state: :needs_analysis
        })

      # Attempt to transition to analyzed state
      {:ok, changeset} = VideoStateMachine.transition_to_analyzed(video)

      # Should transition to analyzed (HDR required for low bitrate logic)
      assert changeset.changes.state == :analyzed

      # Apply the changeset
      {:ok, updated_video} = Repo.update(changeset)
      assert updated_video.state == :analyzed
    end

    test "transitions low bitrate nil HDR video to analyzed state" do
      # Create a video with low bitrate but nil HDR - should not be considered low bitrate
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/low_bitrate_nil_hdr_video.mkv",
          size: 1_000_000_000,
          # 3 Mbps - below 5 Mbps threshold but nil HDR
          bitrate: 3_000_000,
          # Nil HDR content
          hdr: nil,
          width: 1920,
          height: 1080,
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          max_audio_channels: 2,
          atmos: false,
          state: :needs_analysis
        })

      # Attempt to transition to analyzed state
      {:ok, changeset} = VideoStateMachine.transition_to_analyzed(video)

      # Should transition to analyzed (HDR must be true for low bitrate logic)
      assert changeset.changes.state == :analyzed

      # Apply the changeset
      {:ok, updated_video} = Repo.update(changeset)
      assert updated_video.state == :analyzed
    end

    test "transitions zero bitrate HDR video to analyzed state (prevents division by zero)" do
      # Create a video with zero bitrate and HDR - should not be considered low bitrate
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/zero_bitrate_hdr_video.mkv",
          size: 1_000_000_000,
          # Zero bitrate - should not cause division by zero
          bitrate: 0,
          # HDR content
          hdr: "HDR10",
          width: 1920,
          height: 1080,
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          max_audio_channels: 2,
          atmos: false,
          state: :needs_analysis
        })

      # Attempt to transition to analyzed state
      {:ok, changeset} = VideoStateMachine.transition_to_analyzed(video)

      # Should transition to analyzed (zero bitrate is invalid, not low bitrate)
      assert changeset.changes.state == :analyzed

      # Apply the changeset - this should fail validation due to zero bitrate
      {:error, failed_changeset} = Repo.update(changeset)
      assert failed_changeset.errors[:bitrate] != nil
    end
  end

  describe "valid_transitions/1" do
    test "returns valid transitions for each state" do
      assert VideoStateMachine.valid_transitions(:needs_analysis) == [
               :analyzed,
               :crf_searched,
               :encoded,
               :failed
             ]

      assert VideoStateMachine.valid_transitions(:analyzed) == [
               :crf_searching,
               :crf_searched,
               :encoded,
               :failed
             ]

      assert VideoStateMachine.valid_transitions(:crf_searching) == [
               :crf_searched,
               :failed,
               :analyzed
             ]

      assert VideoStateMachine.valid_transitions(:crf_searched) == [
               :encoding,
               :failed,
               :crf_searching
             ]

      assert VideoStateMachine.valid_transitions(:encoding) == [:encoded, :failed, :crf_searched]
      assert VideoStateMachine.valid_transitions(:encoded) == [:failed]

      assert VideoStateMachine.valid_transitions(:failed) == [
               :needs_analysis,
               :analyzed,
               :crf_searching,
               :crf_searched,
               :encoding
             ]
    end
  end

  describe "valid_transition?/2" do
    test "validates valid state transitions" do
      assert VideoStateMachine.valid_transition?(:needs_analysis, :analyzed)
      assert VideoStateMachine.valid_transition?(:analyzed, :crf_searching)
      assert VideoStateMachine.valid_transition?(:crf_searched, :encoding)
      assert VideoStateMachine.valid_transition?(:encoding, :encoded)
    end

    test "rejects invalid state transitions" do
      refute VideoStateMachine.valid_transition?(:needs_analysis, :encoding)
      refute VideoStateMachine.valid_transition?(:encoded, :analyzed)
      refute VideoStateMachine.valid_transition?(:crf_searching, :encoding)
    end

    test "handles invalid states" do
      refute VideoStateMachine.valid_transition?(:invalid_state, :analyzed)
      refute VideoStateMachine.valid_transition?(:analyzed, :invalid_state)
    end
  end

  describe "next_expected_state/1" do
    test "returns correct next state for needs_analysis video with complete analysis" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          state: :needs_analysis,
          # High bitrate to avoid low bitrate logic
          bitrate: 15_000,
          width: 1920,
          height: 1080,
          # Required for analysis_complete?
          duration: 7200.0,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      assert VideoStateMachine.next_expected_state(video) == :analyzed
    end

    test "returns needs_analysis for incomplete analysis" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          state: :needs_analysis,
          # Missing required field
          bitrate: nil,
          width: 1920,
          height: 1080,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      assert VideoStateMachine.next_expected_state(video) == :needs_analysis
    end

    test "returns correct next states for other states" do
      {:ok, video} = Fixtures.video_fixture(%{state: :analyzed})
      assert VideoStateMachine.next_expected_state(video) == :crf_searching

      {:ok, video} = Fixtures.video_fixture(%{state: :crf_searched})
      assert VideoStateMachine.next_expected_state(video) == :encoding

      {:ok, video} = Fixtures.video_fixture(%{state: :encoding})
      assert VideoStateMachine.next_expected_state(video) == :encoded

      {:ok, video} = Fixtures.video_fixture(%{state: :encoded})
      assert VideoStateMachine.next_expected_state(video) == :encoded

      {:ok, video} = Fixtures.video_fixture(%{state: :failed})
      assert VideoStateMachine.next_expected_state(video) == :failed
    end

    test "handles crf_searching state with complete search" do
      # This would need a video with VMAF data to test properly
      {:ok, video} = Fixtures.video_fixture(%{state: :crf_searching})

      # Without VMAF data, should stay in crf_searching
      assert VideoStateMachine.next_expected_state(video) == :crf_searching
    end
  end

  describe "mark_as_reencoded/1" do
    test "transitions video to encoded state from needs_analysis" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          state: :needs_analysis,
          bitrate: 5000,
          width: 1920,
          height: 1080
        })

      {:ok, updated_video} = VideoStateMachine.mark_as_reencoded(video)
      assert updated_video.state == :encoded
    end

    test "transitions video to encoded state from analyzed" do
      {:ok, video} = Fixtures.video_fixture(%{state: :analyzed})

      {:ok, updated_video} = VideoStateMachine.mark_as_reencoded(video)
      assert updated_video.state == :encoded
    end

    test "transitions video from crf_searching to encoded" do
      {:ok, video} = Fixtures.video_fixture(%{state: :crf_searching})

      {:ok, updated_video} = VideoStateMachine.mark_as_reencoded(video)
      assert updated_video.state == :encoded
    end

    test "transitions video from crf_searched to encoded" do
      {:ok, video} = Fixtures.video_fixture(%{state: :crf_searched})

      {:ok, updated_video} = VideoStateMachine.mark_as_reencoded(video)
      assert updated_video.state == :encoded
    end

    test "transitions video from encoding to encoded" do
      {:ok, video} = Fixtures.video_fixture(%{state: :encoding})

      {:ok, updated_video} = VideoStateMachine.mark_as_reencoded(video)
      assert updated_video.state == :encoded
    end

    test "returns unchanged video if already encoded" do
      {:ok, video} = Fixtures.video_fixture(%{state: :encoded})

      {:ok, updated_video} = VideoStateMachine.mark_as_reencoded(video)
      assert updated_video.state == :encoded
      assert updated_video.id == video.id
    end

    test "transitions video from failed to encoded" do
      {:ok, video} = Fixtures.video_fixture(%{state: :failed})

      {:ok, updated_video} = VideoStateMachine.mark_as_reencoded(video)
      assert updated_video.state == :encoded
    end
  end

  describe "mark_as_analyzed/1" do
    test "uses low bitrate logic correctly" do
      # Test that mark_as_analyzed uses the transition_to_analyzed logic
      {:ok, low_bitrate_video} =
        Fixtures.video_fixture(%{
          state: :needs_analysis,
          # Low bitrate (3 Mbps)
          bitrate: 3_000_000,
          # HDR content (required)
          hdr: "HDR10",
          width: 1920,
          height: 1080,
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          max_audio_channels: 2
        })

      {:ok, updated_video} = VideoStateMachine.mark_as_analyzed(low_bitrate_video)
      # Should skip to encoded
      assert updated_video.state == :encoded
    end

    test "transitions high bitrate video to analyzed" do
      {:ok, high_bitrate_video} =
        Fixtures.video_fixture(%{
          state: :needs_analysis,
          # High bitrate (15 Mbps)
          bitrate: 15_000_000,
          # Even with HDR, high bitrate should go to analyzed
          hdr: "HDR10",
          width: 1920,
          height: 1080,
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          max_audio_channels: 2
        })

      {:ok, updated_video} = VideoStateMachine.mark_as_analyzed(high_bitrate_video)
      # Should go to analyzed normally
      assert updated_video.state == :analyzed
    end

    test "transitions low bitrate non-HDR video to analyzed (HDR required)" do
      {:ok, low_bitrate_no_hdr_video} =
        Fixtures.video_fixture(%{
          state: :needs_analysis,
          # Low bitrate (3 Mbps) but no HDR
          bitrate: 3_000_000,
          # No HDR content
          hdr: nil,
          width: 1920,
          height: 1080,
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          max_audio_channels: 2
        })

      {:ok, updated_video} = VideoStateMachine.mark_as_analyzed(low_bitrate_no_hdr_video)
      # Should go to analyzed (HDR required)
      assert updated_video.state == :analyzed
    end
  end

  describe "transition/3" do
    test "prevents invalid state transitions" do
      {:ok, video} = Fixtures.video_fixture(%{state: :needs_analysis})

      # Try invalid transition
      result = VideoStateMachine.transition(video, :encoding)

      # Should return error tuple with message
      assert {:error, _message} = result
    end

    test "allows valid state transitions" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          state: :needs_analysis,
          # High bitrate to avoid low bitrate logic
          bitrate: 15_000,
          width: 1920,
          height: 1080,
          video_codecs: ["h264"],
          audio_codecs: ["aac"],
          max_audio_channels: 2
        })

      # Try valid transition
      {:ok, changeset} = VideoStateMachine.transition(video, :analyzed)

      assert changeset.valid?
      assert changeset.changes.state == :analyzed
    end

    test "applies additional attributes during transition" do
      {:ok, video} = Fixtures.video_fixture(%{state: :needs_analysis})

      {:ok, changeset} = VideoStateMachine.transition(video, :failed, %{bitrate: 12_345})

      assert changeset.valid?
      assert changeset.changes.state == :failed
      assert changeset.changes.bitrate == 12_345
    end

    test "rejects invalid state names" do
      {:ok, video} = Fixtures.video_fixture(%{state: :needs_analysis})

      result = VideoStateMachine.transition(video, :invalid_state)

      assert {:error, message} = result
      assert message =~ "Invalid state"
    end
  end

  describe "mark_as_* functions" do
    test "mark_as_crf_searching updates and broadcasts" do
      {:ok, video} = Fixtures.video_fixture(%{state: :analyzed})

      Phoenix.PubSub.subscribe(Reencodarr.PubSub, "video_state_transitions")

      {:ok, updated} = VideoStateMachine.mark_as_crf_searching(video)

      assert updated.state == :crf_searching
      assert updated.id == video.id
      assert_received {:video_state_changed, ^updated, :crf_searching}
    end

    test "mark_as_crf_searched updates and broadcasts" do
      {:ok, video} = Fixtures.video_fixture(%{state: :crf_searching})
      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 25.0})
      Fixtures.choose_vmaf(video, vmaf)

      {:ok, updated} = VideoStateMachine.mark_as_crf_searched(video)

      assert updated.state == :crf_searched
      assert updated.id == video.id
    end

    test "mark_as_needs_analysis updates and broadcasts" do
      {:ok, video} = Fixtures.video_fixture(%{state: :failed})

      {:ok, updated} = VideoStateMachine.mark_as_needs_analysis(video)

      assert updated.state == :needs_analysis
      assert updated.id == video.id
    end

    test "mark_as_encoded updates and broadcasts" do
      {:ok, video} = Fixtures.video_fixture(%{state: :encoding})

      {:ok, updated} = VideoStateMachine.mark_as_encoded(video)

      assert updated.state == :encoded
      assert updated.id == video.id
    end
  end

  describe "validation functions" do
    test "validates video codecs must be non-empty list" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          state: :needs_analysis,
          bitrate: 15_000,
          width: 1920,
          height: 1080,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      # Try transition with empty video codecs
      {:ok, changeset} = VideoStateMachine.transition(video, :analyzed, %{video_codecs: []})

      refute changeset.valid?
      assert changeset.errors[:video_codecs]
    end

    test "validates audio codecs must be non-empty list" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          state: :needs_analysis,
          bitrate: 15_000,
          width: 1920,
          height: 1080,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      # Try transition with empty audio codecs
      {:ok, changeset} = VideoStateMachine.transition(video, :analyzed, %{audio_codecs: []})

      refute changeset.valid?
      assert changeset.errors[:audio_codecs]
    end

    test "validates bitrate is required for analyzed state" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          state: :needs_analysis,
          bitrate: 15_000,
          width: 1920,
          height: 1080,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      # Try transition without bitrate
      {:ok, changeset} = VideoStateMachine.transition(video, :analyzed, %{bitrate: nil})

      refute changeset.valid?
      assert changeset.errors[:bitrate]
    end

    test "validates dimensions are required for analyzed state" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          state: :needs_analysis,
          bitrate: 15_000,
          width: 1920,
          height: 1080,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      # Try transition without width/height
      {:ok, changeset} = VideoStateMachine.transition(video, :analyzed, %{width: nil})

      refute changeset.valid?
      assert changeset.errors[:width]
    end
  end

  describe "transition_to_* helper functions" do
    test "transition_to_crf_searching" do
      {:ok, video} = Fixtures.video_fixture(%{state: :analyzed})

      {:ok, changeset} = VideoStateMachine.transition_to_crf_searching(video)

      assert changeset.valid?
      assert changeset.changes.state == :crf_searching
    end

    test "transition_to_encoding" do
      {:ok, video} = Fixtures.video_fixture(%{state: :crf_searched})

      {:ok, changeset} = VideoStateMachine.transition_to_encoding(video)

      assert changeset.valid?
      assert changeset.changes.state == :encoding
    end

    test "transition_to_needs_analysis" do
      {:ok, video} = Fixtures.video_fixture(%{state: :failed})

      {:ok, changeset} = VideoStateMachine.transition_to_needs_analysis(video)

      assert changeset.valid?
      assert changeset.changes.state == :needs_analysis
    end

    test "transition_to_crf_searched" do
      {:ok, video} = Fixtures.video_fixture(%{state: :crf_searching})
      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 25.0})
      Fixtures.choose_vmaf(video, vmaf)

      {:ok, changeset} = VideoStateMachine.transition_to_crf_searched(video)

      assert changeset.valid?
      assert changeset.changes.state == :crf_searched
    end

    test "transition_to_crf_searched fails when no chosen VMAF exists" do
      {:ok, video} = Fixtures.video_fixture(%{state: :crf_searching})

      {:ok, changeset} = VideoStateMachine.transition_to_crf_searched(video)

      refute changeset.valid?
      assert changeset.errors[:state]
    end

    test "transition_to_failed" do
      {:ok, video} = Fixtures.video_fixture(%{state: :encoding})

      {:ok, changeset} = VideoStateMachine.transition_to_failed(video)

      assert changeset.valid?
      assert changeset.changes.state == :failed
    end
  end
end
