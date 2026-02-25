defmodule Reencodarr.Analyzer.Broadway.ProducerTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  alias Reencodarr.PipelineStateMachine

  describe "pause handler - state machine behavior" do
    test "pause from :processing transitions to :pausing" do
      pipeline =
        PipelineStateMachine.new(:analyzer)
        |> PipelineStateMachine.resume()
        |> PipelineStateMachine.start_processing()

      paused = PipelineStateMachine.handle_pause_request(pipeline)
      assert PipelineStateMachine.get_state(paused) == :pausing
    end

    test "pause when already :pausing stays in :pausing" do
      pipeline =
        PipelineStateMachine.new(:analyzer)
        |> PipelineStateMachine.resume()
        |> PipelineStateMachine.start_processing()
        |> PipelineStateMachine.pause()

      result = PipelineStateMachine.handle_pause_request(pipeline)

      # Should stay in pausing, not transition
      assert PipelineStateMachine.get_state(result) == :pausing
      assert result == pipeline
    end

    test "pause from :running goes straight to :paused" do
      pipeline = PipelineStateMachine.new(:analyzer) |> PipelineStateMachine.resume()

      paused = PipelineStateMachine.handle_pause_request(pipeline)
      assert PipelineStateMachine.get_state(paused) == :paused
    end

    test "pause from :idle goes straight to :paused" do
      pipeline =
        PipelineStateMachine.new(:analyzer)
        |> PipelineStateMachine.resume()
        |> PipelineStateMachine.transition_to(:idle)

      paused = PipelineStateMachine.handle_pause_request(pipeline)
      assert PipelineStateMachine.get_state(paused) == :paused
    end

    test "pause from :paused stays :paused" do
      pipeline = PipelineStateMachine.new(:analyzer)

      paused = PipelineStateMachine.handle_pause_request(pipeline)
      assert PipelineStateMachine.get_state(paused) == :paused
    end
  end

  describe "state transition flow" do
    test "full pause flow: processing -> pausing -> paused" do
      pipeline =
        PipelineStateMachine.new(:analyzer)
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
        PipelineStateMachine.new(:analyzer)
        |> PipelineStateMachine.resume()

      paused = PipelineStateMachine.handle_pause_request(pipeline)
      assert PipelineStateMachine.get_state(paused) == :paused
    end

    test "work completion transitions based on availability" do
      pipeline =
        PipelineStateMachine.new(:analyzer)
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
        PipelineStateMachine.new(:analyzer)
        |> PipelineStateMachine.resume()
        |> PipelineStateMachine.start_processing()
        |> PipelineStateMachine.pause()

      paused = PipelineStateMachine.work_completed(pipeline, false)
      assert PipelineStateMachine.get_state(paused) == :paused
    end
  end
end
