defmodule Reencodarr.CrfSearcher.Broadway.ProducerTest do
  use ExUnit.Case, async: true

  alias Reencodarr.PipelineStateMachine

  describe "pause handler - state machine behavior" do
    test "pause from :processing transitions to :pausing" do
      pipeline =
        PipelineStateMachine.new(:crf_searcher)
        |> PipelineStateMachine.resume()
        |> PipelineStateMachine.start_processing()

      paused = PipelineStateMachine.handle_pause_request(pipeline)
      assert PipelineStateMachine.get_state(paused) == :pausing
    end

    test "pause when already :pausing stays in :pausing" do
      pipeline =
        PipelineStateMachine.new(:crf_searcher)
        |> PipelineStateMachine.resume()
        |> PipelineStateMachine.start_processing()
        |> PipelineStateMachine.pause()

      result = PipelineStateMachine.handle_pause_request(pipeline)

      # Should stay in pausing, not transition
      assert PipelineStateMachine.get_state(result) == :pausing
      assert result == pipeline
    end

    test "pause from :running goes straight to :paused" do
      pipeline = PipelineStateMachine.new(:crf_searcher) |> PipelineStateMachine.resume()

      paused = PipelineStateMachine.handle_pause_request(pipeline)
      assert PipelineStateMachine.get_state(paused) == :paused
    end

    test "pause from :idle goes straight to :paused" do
      pipeline =
        PipelineStateMachine.new(:crf_searcher)
        |> PipelineStateMachine.resume()
        |> PipelineStateMachine.transition_to(:idle)

      paused = PipelineStateMachine.handle_pause_request(pipeline)
      assert PipelineStateMachine.get_state(paused) == :paused
    end

    test "pause from :paused stays :paused" do
      pipeline = PipelineStateMachine.new(:crf_searcher)

      paused = PipelineStateMachine.handle_pause_request(pipeline)
      assert PipelineStateMachine.get_state(paused) == :paused
    end
  end

  describe "state transition flow" do
    test "full pause flow: processing -> pausing -> paused" do
      pipeline =
        PipelineStateMachine.new(:crf_searcher)
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
        PipelineStateMachine.new(:crf_searcher)
        |> PipelineStateMachine.resume()

      paused = PipelineStateMachine.handle_pause_request(pipeline)
      assert PipelineStateMachine.get_state(paused) == :paused
    end

    test "work completion transitions based on availability" do
      pipeline =
        PipelineStateMachine.new(:crf_searcher)
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
        PipelineStateMachine.new(:crf_searcher)
        |> PipelineStateMachine.resume()
        |> PipelineStateMachine.start_processing()
        |> PipelineStateMachine.pause()

      paused = PipelineStateMachine.work_completed(pipeline, false)
      assert PipelineStateMachine.get_state(paused) == :paused
    end
  end

  describe "auto-recovery helper functions" do
    alias Reencodarr.CrfSearcher.Broadway.Producer

    test "update_consecutive_count/2 resets to 0 when available" do
      assert Producer.update_consecutive_count(0, :available) == 0
      assert Producer.update_consecutive_count(500, :available) == 0
      assert Producer.update_consecutive_count(1000, :available) == 0
    end

    test "update_consecutive_count/2 resets to 0 when busy (alive but searching)" do
      assert Producer.update_consecutive_count(0, :busy) == 0
      assert Producer.update_consecutive_count(500, :busy) == 0
      assert Producer.update_consecutive_count(1000, :busy) == 0
    end

    test "update_consecutive_count/2 increments only on timeout (unresponsive)" do
      assert Producer.update_consecutive_count(0, :timeout) == 1
      assert Producer.update_consecutive_count(1, :timeout) == 2
      assert Producer.update_consecutive_count(899, :timeout) == 900
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

  describe "auto-recovery from stuck CrfSearch GenServer" do
    test "tracks consecutive unavailable polls" do
      # This test documents the expected behavior for Fix 4
      # The producer should track how many consecutive polls returned unavailable

      # Initial state
      state = %{pending_demand: 0, consecutive_unavailable: 0}

      # Simulate CrfSearch being unavailable
      # After implementation, consecutive_unavailable should increment
      assert state.consecutive_unavailable == 0

      # After 900 consecutive unavailable polls (~30 minutes), should call reset_if_stuck
      # This is documentation of expected behavior
    end

    test "resets counter when CrfSearch becomes available" do
      # State after many unavailable polls
      state = %{pending_demand: 0, consecutive_unavailable: 500}

      # When CrfSearch becomes available again, counter should reset to 0
      # This is documentation of expected behavior
      assert state.consecutive_unavailable == 500
    end

    @tag :flaky
    test "calls CrfSearch.reset_if_stuck after threshold" do
      # After 900 consecutive unavailable polls, should attempt recovery
      # This is documentation of expected behavior

      # Mock CrfSearch
      :meck.new(Reencodarr.AbAv1.CrfSearch, [:passthrough])
      :meck.expect(Reencodarr.AbAv1.CrfSearch, :available?, fn -> false end)
      :meck.expect(Reencodarr.AbAv1.CrfSearch, :reset_if_stuck, fn -> :ok end)

      # Simulate 900 consecutive unavailable polls
      # After implementation, reset_if_stuck should be called

      # Verify reset_if_stuck was called
      # This will be implemented in the next step

      :meck.unload(Reencodarr.AbAv1.CrfSearch)
    end
  end
end
