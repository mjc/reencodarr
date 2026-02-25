defmodule Reencodarr.PipelineStateMachineTest do
  use ExUnit.Case, async: true
  use Reencodarr.DataCase
  @moduletag capture_log: true

  alias Reencodarr.PipelineStateMachine

  import ExUnit.CaptureLog

  describe "struct creation and basic operations" do
    test "new/1 creates a pipeline state machine with initial state" do
      pipeline = PipelineStateMachine.new(:analyzer)

      assert %PipelineStateMachine{
               service: :analyzer,
               current_state: :paused
             } = pipeline
    end

    test "new/1 works for all valid services" do
      for service <- [:analyzer, :crf_searcher, :encoder] do
        pipeline = PipelineStateMachine.new(service)
        assert pipeline.service == service
        assert pipeline.current_state == :paused
      end
    end

    test "get_state/1 returns the current state" do
      pipeline = PipelineStateMachine.new(:analyzer)
      assert PipelineStateMachine.get_state(pipeline) == :paused
    end

    test "transition_to/2 updates state with valid transitions" do
      pipeline = PipelineStateMachine.new(:analyzer)

      # Test valid transition
      updated = PipelineStateMachine.transition_to(pipeline, :running)
      assert PipelineStateMachine.get_state(updated) == :running

      # Test another valid transition
      processing = PipelineStateMachine.transition_to(updated, :processing)
      assert PipelineStateMachine.get_state(processing) == :processing
    end

    test "transition_to/2 logs warning and returns unchanged state for invalid transitions" do
      # starts in :paused
      pipeline = PipelineStateMachine.new(:analyzer)

      log =
        capture_log(fn ->
          # Try invalid transition from :paused to :processing (should go through :running first)
          result = PipelineStateMachine.transition_to(pipeline, :processing)
          # unchanged
          assert PipelineStateMachine.get_state(result) == :paused
        end)

      assert log =~ "Invalid state transition for analyzer from paused to processing"
    end
  end

  describe "high-level operations" do
    test "pause/1 handles different states correctly" do
      analyzer = PipelineStateMachine.new(:analyzer)

      # From paused -> paused (no change) - captures warning log
      _log =
        capture_log(fn ->
          paused = PipelineStateMachine.pause(analyzer)
          assert PipelineStateMachine.get_state(paused) == :paused
        end)

      # From running -> paused
      running = PipelineStateMachine.transition_to(analyzer, :running)
      paused_from_running = PipelineStateMachine.pause(running)
      assert PipelineStateMachine.get_state(paused_from_running) == :paused

      # From idle -> paused
      idle = PipelineStateMachine.transition_to(analyzer, :idle)
      paused_from_idle = PipelineStateMachine.pause(idle)
      assert PipelineStateMachine.get_state(paused_from_idle) == :paused

      # From processing -> pausing (needs to finish current work)
      processing = PipelineStateMachine.transition_to(running, :processing)
      pausing = PipelineStateMachine.pause(processing)
      assert PipelineStateMachine.get_state(pausing) == :pausing

      # From stopped -> paused
      stopped = PipelineStateMachine.transition_to(analyzer, :stopped)
      paused_from_stopped = PipelineStateMachine.pause(stopped)
      assert PipelineStateMachine.get_state(paused_from_stopped) == :paused
    end

    test "resume/1 handles different states correctly" do
      analyzer = PipelineStateMachine.new(:analyzer)

      # From paused -> running
      resumed = PipelineStateMachine.resume(analyzer)
      assert PipelineStateMachine.get_state(resumed) == :running

      # From stopped -> running
      stopped = PipelineStateMachine.transition_to(analyzer, :stopped)
      resumed_from_stopped = PipelineStateMachine.resume(stopped)
      assert PipelineStateMachine.get_state(resumed_from_stopped) == :running

      # From running -> running (no change) - captures warning log
      running = PipelineStateMachine.transition_to(analyzer, :running)

      _log =
        capture_log(fn ->
          resumed_from_running = PipelineStateMachine.resume(running)
          assert PipelineStateMachine.get_state(resumed_from_running) == :running
        end)

      # From processing -> processing (no change) - captures warning log
      processing = PipelineStateMachine.transition_to(running, :processing)

      _log =
        capture_log(fn ->
          resumed_from_processing = PipelineStateMachine.resume(processing)
          assert PipelineStateMachine.get_state(resumed_from_processing) == :processing
        end)
    end

    test "work_completed/2 handles different scenarios correctly" do
      analyzer = PipelineStateMachine.new(:analyzer)
      running = PipelineStateMachine.transition_to(analyzer, :running)
      processing = PipelineStateMachine.transition_to(running, :processing)

      # From processing with more work -> running
      completed_with_more = PipelineStateMachine.work_completed(processing, true)
      assert PipelineStateMachine.get_state(completed_with_more) == :running

      # From processing without more work -> idle
      completed_without_more = PipelineStateMachine.work_completed(processing, false)
      assert PipelineStateMachine.get_state(completed_without_more) == :idle

      # From pausing -> paused (finish pausing process)
      pausing = PipelineStateMachine.transition_to(processing, :pausing)
      completed_pausing = PipelineStateMachine.work_completed(pausing, false)
      assert PipelineStateMachine.get_state(completed_pausing) == :paused

      # From other states -> no change (captures warning for self-transition)
      _log =
        capture_log(fn ->
          completed_from_running = PipelineStateMachine.work_completed(running, true)
          assert PipelineStateMachine.get_state(completed_from_running) == :running
        end)
    end

    test "work_available/1 transitions idle to running" do
      analyzer = PipelineStateMachine.new(:analyzer)
      running = PipelineStateMachine.transition_to(analyzer, :running)
      idle = PipelineStateMachine.transition_to(running, :idle)

      # From idle -> running
      available = PipelineStateMachine.work_available(idle)
      assert PipelineStateMachine.get_state(available) == :running

      # From other states -> no change
      available_from_running = PipelineStateMachine.work_available(running)
      assert PipelineStateMachine.get_state(available_from_running) == :running

      available_from_paused = PipelineStateMachine.work_available(analyzer)
      assert PipelineStateMachine.get_state(available_from_paused) == :paused
    end

    test "start_processing/1 transitions ready states to processing" do
      analyzer = PipelineStateMachine.new(:analyzer)
      running = PipelineStateMachine.transition_to(analyzer, :running)
      idle = PipelineStateMachine.transition_to(running, :idle)

      # From running -> processing
      processing_from_running = PipelineStateMachine.start_processing(running)
      assert PipelineStateMachine.get_state(processing_from_running) == :processing

      # From idle -> processing
      processing_from_idle = PipelineStateMachine.start_processing(idle)
      assert PipelineStateMachine.get_state(processing_from_idle) == :processing

      # From paused -> no change (not ready)
      processing_from_paused = PipelineStateMachine.start_processing(analyzer)
      assert PipelineStateMachine.get_state(processing_from_paused) == :paused
    end
  end

  describe "state query functions with structs" do
    test "running?/1 works with pipeline struct" do
      # :paused
      analyzer = PipelineStateMachine.new(:analyzer)
      refute PipelineStateMachine.running?(analyzer)

      running = PipelineStateMachine.transition_to(analyzer, :running)
      assert PipelineStateMachine.running?(running)

      idle = PipelineStateMachine.transition_to(running, :idle)
      assert PipelineStateMachine.running?(idle)

      processing = PipelineStateMachine.transition_to(running, :processing)
      assert PipelineStateMachine.running?(processing)

      pausing = PipelineStateMachine.transition_to(processing, :pausing)
      assert PipelineStateMachine.running?(pausing)

      stopped = PipelineStateMachine.transition_to(analyzer, :stopped)
      refute PipelineStateMachine.running?(stopped)
    end

    test "actively_working?/1 works with pipeline struct" do
      analyzer = PipelineStateMachine.new(:analyzer)
      refute PipelineStateMachine.actively_working?(analyzer)

      running = PipelineStateMachine.transition_to(analyzer, :running)
      refute PipelineStateMachine.actively_working?(running)

      processing = PipelineStateMachine.transition_to(running, :processing)
      assert PipelineStateMachine.actively_working?(processing)
    end

    test "available_for_work?/1 works with pipeline struct" do
      # :paused
      analyzer = PipelineStateMachine.new(:analyzer)
      refute PipelineStateMachine.available_for_work?(analyzer)

      running = PipelineStateMachine.transition_to(analyzer, :running)
      assert PipelineStateMachine.available_for_work?(running)

      idle = PipelineStateMachine.transition_to(running, :idle)
      assert PipelineStateMachine.available_for_work?(idle)

      processing = PipelineStateMachine.transition_to(running, :processing)
      refute PipelineStateMachine.available_for_work?(processing)
    end
  end

  describe "broadcasting integration with structs" do
    setup do
      # Subscribe to events to test broadcasting
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, "analyzer")
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, "crf_searcher")
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, "encoder")
      :ok
    end

    test "new/1 broadcasts initial state transition" do
      PipelineStateMachine.new(:analyzer)

      # Should receive initial state broadcast
      assert_receive {:analyzer, :paused}, 100
    end

    test "transition_to/2 broadcasts state changes" do
      pipeline = PipelineStateMachine.new(:crf_searcher)
      # Clear initial broadcast message
      receive do
        {:crf_searcher, :paused} -> :ok
      after
        100 -> :ok
      end

      PipelineStateMachine.transition_to(pipeline, :running)

      # Should receive state change broadcast
      assert_receive {:crf_searcher, :running}, 100
    end

    test "high-level operations broadcast correctly" do
      pipeline = PipelineStateMachine.new(:encoder)
      # Clear initial broadcast message
      receive do
        {:encoder, :paused} -> :ok
      after
        100 -> :ok
      end

      # Resume should broadcast
      PipelineStateMachine.resume(pipeline)
      assert_receive {:encoder, :running}, 100
    end
  end

  describe "edge cases and error handling" do
    test "invalid service in new/1 raises error" do
      assert_raise FunctionClauseError, fn ->
        PipelineStateMachine.new(:invalid_service)
      end
    end

    test "concurrent state transitions work correctly" do
      # Test that multiple rapid transitions work
      pipeline = PipelineStateMachine.new(:analyzer)

      result =
        pipeline
        # paused -> running
        |> PipelineStateMachine.resume()
        # running -> processing
        |> PipelineStateMachine.start_processing()
        # processing -> pausing
        |> PipelineStateMachine.pause()
        # pausing -> paused
        |> PipelineStateMachine.work_completed(false)
        # paused -> running
        |> PipelineStateMachine.resume()

      assert PipelineStateMachine.get_state(result) == :running
    end

    test "work_completed with pausing state always goes to paused regardless of more_work flag" do
      pipeline =
        PipelineStateMachine.new(:encoder)
        |> PipelineStateMachine.resume()
        |> PipelineStateMachine.start_processing()
        # processing -> pausing
        |> PipelineStateMachine.pause()

      # Even with more work available, pausing should go to paused
      completed = PipelineStateMachine.work_completed(pipeline, true)
      assert PipelineStateMachine.get_state(completed) == :paused

      # Same result without more work
      pipeline2 =
        PipelineStateMachine.new(:encoder)
        |> PipelineStateMachine.resume()
        |> PipelineStateMachine.start_processing()
        |> PipelineStateMachine.pause()

      completed2 = PipelineStateMachine.work_completed(pipeline2, false)
      assert PipelineStateMachine.get_state(completed2) == :paused
    end
  end

  describe "handle_pause_request/1 - pause with duplicate handling" do
    test "pauses from :processing to :pausing" do
      analyzer = PipelineStateMachine.new(:analyzer)
      running = PipelineStateMachine.transition_to(analyzer, :running)
      processing = PipelineStateMachine.transition_to(running, :processing)

      paused = PipelineStateMachine.handle_pause_request(processing)
      assert PipelineStateMachine.get_state(paused) == :pausing
    end

    test "ignores duplicate pause when already :pausing" do
      analyzer = PipelineStateMachine.new(:analyzer)
      running = PipelineStateMachine.transition_to(analyzer, :running)
      processing = PipelineStateMachine.transition_to(running, :processing)
      pausing = PipelineStateMachine.transition_to(processing, :pausing)

      # Send pause again while already pausing
      result = PipelineStateMachine.handle_pause_request(pausing)

      # Should remain in :pausing, not transition to :paused
      assert PipelineStateMachine.get_state(result) == :pausing
      # Should be the same struct (no transition)
      assert result == pausing
    end

    test "transitions to :paused from :idle" do
      analyzer = PipelineStateMachine.new(:analyzer)
      running = PipelineStateMachine.transition_to(analyzer, :running)
      idle = PipelineStateMachine.transition_to(running, :idle)

      paused = PipelineStateMachine.handle_pause_request(idle)
      assert PipelineStateMachine.get_state(paused) == :paused
    end

    test "transitions to :paused from :running" do
      analyzer = PipelineStateMachine.new(:analyzer)
      running = PipelineStateMachine.transition_to(analyzer, :running)

      paused = PipelineStateMachine.handle_pause_request(running)
      assert PipelineStateMachine.get_state(paused) == :paused
    end

    test "transitions to :paused from :stopped" do
      analyzer = PipelineStateMachine.new(:analyzer)
      stopped = PipelineStateMachine.transition_to(analyzer, :stopped)

      paused = PipelineStateMachine.handle_pause_request(stopped)
      assert PipelineStateMachine.get_state(paused) == :paused
    end

    test "transitions to :paused from :paused (no-op)" do
      analyzer = PipelineStateMachine.new(:analyzer)

      paused = PipelineStateMachine.handle_pause_request(analyzer)
      assert PipelineStateMachine.get_state(paused) == :paused
    end

    test "handles full pause flow: processing -> pausing -> paused" do
      analyzer = PipelineStateMachine.new(:analyzer)
      running = PipelineStateMachine.transition_to(analyzer, :running)
      processing = PipelineStateMachine.transition_to(running, :processing)

      # First pause request: processing -> pausing
      pausing = PipelineStateMachine.handle_pause_request(processing)
      assert PipelineStateMachine.get_state(pausing) == :pausing

      # Second pause request (duplicate): should stay pausing
      still_pausing = PipelineStateMachine.handle_pause_request(pausing)
      assert PipelineStateMachine.get_state(still_pausing) == :pausing

      # Work completes: pausing -> paused
      paused = PipelineStateMachine.work_completed(still_pausing, false)
      assert PipelineStateMachine.get_state(paused) == :paused
    end

    test "handles pause while no work: running -> paused directly" do
      analyzer = PipelineStateMachine.new(:analyzer)
      running = PipelineStateMachine.transition_to(analyzer, :running)

      paused = PipelineStateMachine.handle_pause_request(running)
      assert PipelineStateMachine.get_state(paused) == :paused
    end
  end
end
