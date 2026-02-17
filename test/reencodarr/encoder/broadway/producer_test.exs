defmodule Reencodarr.Encoder.Broadway.ProducerTest do
  use Reencodarr.UnitCase, async: true

  alias Reencodarr.PipelineStateMachine

  # Helper function to test pattern matching logic
  defp match_return_value(value) do
    case value do
      %Reencodarr.Media.Vmaf{} -> :single_vmaf
      [%Reencodarr.Media.Vmaf{} | _] -> :list_with_vmaf
      [] -> :empty_list
      nil -> :nil_value
    end
  end

  describe "get_next_vmaf/1" do
    test "handles different return types from Media.get_next_for_encoding/1" do
      # Test the pattern matching logic without calling the actual Media function
      # This tests our case clause logic

      # Test the pattern matching logic without calling the actual Media function
      # This tests our case clause logic

      # Case 1: Single VMAF struct (when limit = 1)
      vmaf = %Reencodarr.Media.Vmaf{id: 1, video: %{path: "/test.mkv"}}
      assert match_return_value(vmaf) == :single_vmaf

      # Case 2: List with one VMAF
      assert match_return_value([vmaf]) == :list_with_vmaf

      # Case 3: Empty list
      assert match_return_value([]) == :empty_list

      # Case 4: nil
      assert match_return_value(nil) == :nil_value
    end
  end

  describe "pause handler" do
    test "pause from :processing transitions to :pausing" do
      pipeline =
        PipelineStateMachine.new(:encoder)
        |> PipelineStateMachine.resume()
        |> PipelineStateMachine.start_processing()

      paused = PipelineStateMachine.handle_pause_request(pipeline)
      assert PipelineStateMachine.get_state(paused) == :pausing
    end

    test "pause when already :pausing stays in :pausing" do
      pipeline =
        PipelineStateMachine.new(:encoder)
        |> PipelineStateMachine.resume()
        |> PipelineStateMachine.start_processing()
        |> PipelineStateMachine.pause()

      result = PipelineStateMachine.handle_pause_request(pipeline)

      # Should stay in pausing, not transition
      assert PipelineStateMachine.get_state(result) == :pausing
      assert result == pipeline
    end

    test "pause from :running goes straight to :paused" do
      pipeline = PipelineStateMachine.new(:encoder) |> PipelineStateMachine.resume()

      paused = PipelineStateMachine.handle_pause_request(pipeline)
      assert PipelineStateMachine.get_state(paused) == :paused
    end

    test "pause from :idle goes straight to :paused" do
      pipeline =
        PipelineStateMachine.new(:encoder)
        |> PipelineStateMachine.resume()
        |> PipelineStateMachine.transition_to(:idle)

      paused = PipelineStateMachine.handle_pause_request(pipeline)
      assert PipelineStateMachine.get_state(paused) == :paused
    end

    test "pause from :paused stays :paused" do
      pipeline = PipelineStateMachine.new(:encoder)

      paused = PipelineStateMachine.handle_pause_request(pipeline)
      assert PipelineStateMachine.get_state(paused) == :paused
    end
  end

  describe "state transition flow" do
    test "full pause flow: processing -> pausing -> paused" do
      pipeline =
        PipelineStateMachine.new(:encoder)
        |> PipelineStateMachine.resume()
        |> PipelineStateMachine.start_processing()

      # First pause request: processing -> pausing
      pausing = PipelineStateMachine.handle_pause_request(pipeline)
      assert PipelineStateMachine.get_state(pausing) == :pausing

      # Second pause request (duplicate): should stay pausing
      still_pausing = PipelineStateMachine.handle_pause_request(pausing)
      assert PipelineStateMachine.get_state(still_pausing) == :pausing

      # Work completes: pausing -> paused
      paused = PipelineStateMachine.work_completed(still_pausing, false)
      assert PipelineStateMachine.get_state(paused) == :paused
    end

    test "pause while no work: running -> paused directly" do
      pipeline =
        PipelineStateMachine.new(:encoder)
        |> PipelineStateMachine.resume()

      paused = PipelineStateMachine.handle_pause_request(pipeline)
      assert PipelineStateMachine.get_state(paused) == :paused
    end

    test "work completion transitions based on availability" do
      pipeline =
        PipelineStateMachine.new(:encoder)
        |> PipelineStateMachine.resume()
        |> PipelineStateMachine.start_processing()

      # Work completed with more work available
      with_more = PipelineStateMachine.work_completed(pipeline, true)
      assert PipelineStateMachine.get_state(with_more) == :running

      # Work completed with no more work
      no_more = PipelineStateMachine.work_completed(pipeline, false)
      assert PipelineStateMachine.get_state(no_more) == :idle
    end

    test "work completion during pausing finalizes pause" do
      pipeline =
        PipelineStateMachine.new(:encoder)
        |> PipelineStateMachine.resume()
        |> PipelineStateMachine.start_processing()
        |> PipelineStateMachine.pause()

      paused = PipelineStateMachine.work_completed(pipeline, false)
      assert PipelineStateMachine.get_state(paused) == :paused
    end
  end

  describe "auto-recovery helper functions" do
    alias Reencodarr.Encoder.Broadway.Producer

    test "update_consecutive_count/2 resets to 0 when available" do
      assert Producer.update_consecutive_count(0, true) == 0
      assert Producer.update_consecutive_count(500, true) == 0
      assert Producer.update_consecutive_count(1000, true) == 0
    end

    test "update_consecutive_count/2 increments when unavailable" do
      assert Producer.update_consecutive_count(0, false) == 1
      assert Producer.update_consecutive_count(1, false) == 2
      assert Producer.update_consecutive_count(899, false) == 900
    end

    test "should_attempt_recovery?/1 returns false below threshold" do
      refute Producer.should_attempt_recovery?(0)
      refute Producer.should_attempt_recovery?(1)
      refute Producer.should_attempt_recovery?(899)
    end

    test "should_attempt_recovery?/1 returns true at threshold" do
      assert Producer.should_attempt_recovery?(900)
    end

    test "should_attempt_recovery?/1 returns true at multiples of threshold" do
      assert Producer.should_attempt_recovery?(1800)
      assert Producer.should_attempt_recovery?(2700)
      assert Producer.should_attempt_recovery?(3600)
    end

    test "should_attempt_recovery?/1 returns false between threshold multiples" do
      refute Producer.should_attempt_recovery?(901)
      refute Producer.should_attempt_recovery?(1799)
      refute Producer.should_attempt_recovery?(1801)
    end
  end
end
