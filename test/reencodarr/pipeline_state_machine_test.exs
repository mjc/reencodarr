defmodule Reencodarr.PipelineStateMachineTest do
  use ExUnit.Case, async: true
  use Reencodarr.DataCase

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

  describe "producer integration helpers" do
    test "handle_pause_cast/1 returns proper GenStage response" do
      state = %{pipeline: PipelineStateMachine.new(:analyzer), other_field: :value}

      # Captures warning log for pausing already paused pipeline
      _log =
        capture_log(fn ->
          assert {:noreply, [], new_state} = PipelineStateMachine.handle_pause_cast(state)
          assert PipelineStateMachine.get_state(new_state.pipeline) == :paused
          assert new_state.other_field == :value
        end)
    end

    test "handle_pause_cast/2 works with custom field name" do
      state = %{custom_pipeline: PipelineStateMachine.new(:crf_searcher), other_field: :value}

      # Captures warning log for pausing already paused pipeline
      _log =
        capture_log(fn ->
          assert {:noreply, [], new_state} =
                   PipelineStateMachine.handle_pause_cast(state, :custom_pipeline)

          assert PipelineStateMachine.get_state(new_state.custom_pipeline) == :paused
          assert new_state.other_field == :value
        end)
    end

    test "handle_resume_cast/2 calls dispatch function and returns response" do
      state = %{pipeline: PipelineStateMachine.new(:encoder)}
      {:ok, dispatch_called} = Agent.start_link(fn -> false end)

      dispatch_func = fn new_state ->
        Agent.update(dispatch_called, fn _ -> true end)
        {:noreply, [], new_state}
      end

      assert {:noreply, [], updated_state} =
               PipelineStateMachine.handle_resume_cast(state, dispatch_func)

      # Pipeline should be resumed
      assert PipelineStateMachine.get_state(updated_state.pipeline) == :running
      # Dispatch function should have been called
      assert Agent.get(dispatch_called, & &1) == true
    end

    test "handle_resume_cast/3 works with custom field name" do
      state = %{custom_pipeline: PipelineStateMachine.new(:analyzer)}

      dispatch_func = fn new_state -> {:noreply, [], new_state} end

      assert {:noreply, [], updated_state} =
               PipelineStateMachine.handle_resume_cast(state, dispatch_func, :custom_pipeline)

      assert PipelineStateMachine.get_state(updated_state.custom_pipeline) == :running
    end

    test "handle_work_completion_cast/3 handles work completion without more work" do
      running_pipeline = PipelineStateMachine.new(:analyzer) |> PipelineStateMachine.resume()
      processing_pipeline = PipelineStateMachine.start_processing(running_pipeline)
      state = %{pipeline: processing_pipeline}

      dispatch_func = fn new_state -> {:noreply, [], new_state} end

      assert {:noreply, [], updated_state} =
               PipelineStateMachine.handle_work_completion_cast(state, false, dispatch_func)

      # Should transition from processing to idle
      assert PipelineStateMachine.get_state(updated_state.pipeline) == :idle
    end

    test "handle_work_completion_cast/4 continues dispatching with more work" do
      running_pipeline = PipelineStateMachine.new(:crf_searcher) |> PipelineStateMachine.resume()
      processing_pipeline = PipelineStateMachine.start_processing(running_pipeline)
      state = %{pipeline: processing_pipeline}
      {:ok, dispatch_called} = Agent.start_link(fn -> false end)

      dispatch_func = fn new_state ->
        Agent.update(dispatch_called, fn _ -> true end)
        {:noreply, [], new_state}
      end

      assert {:noreply, [], updated_state} =
               PipelineStateMachine.handle_work_completion_cast(state, true, dispatch_func)

      # Should transition from processing to running
      assert PipelineStateMachine.get_state(updated_state.pipeline) == :running
      # Should call dispatch function since more work is available
      assert Agent.get(dispatch_called, & &1) == true
    end

    test "handle_dispatch_available_cast/2 handles pausing to paused transition" do
      running_pipeline = PipelineStateMachine.new(:encoder) |> PipelineStateMachine.resume()
      processing_pipeline = PipelineStateMachine.start_processing(running_pipeline)
      # processing -> pausing
      pausing_pipeline = PipelineStateMachine.pause(processing_pipeline)
      state = %{pipeline: pausing_pipeline}

      dispatch_func = fn new_state -> {:noreply, [], new_state} end

      assert {:noreply, [], updated_state} =
               PipelineStateMachine.handle_dispatch_available_cast(state, dispatch_func)

      # Should transition from pausing to paused
      assert PipelineStateMachine.get_state(updated_state.pipeline) == :paused
    end

    test "handle_dispatch_available_cast/3 continues dispatching when available" do
      state = %{pipeline: PipelineStateMachine.new(:analyzer) |> PipelineStateMachine.resume()}
      {:ok, dispatch_called} = Agent.start_link(fn -> false end)

      dispatch_func = fn new_state ->
        Agent.update(dispatch_called, fn _ -> true end)
        {:noreply, [], new_state}
      end

      assert {:noreply, [], _updated_state} =
               PipelineStateMachine.handle_dispatch_available_cast(state, dispatch_func)

      # Should call dispatch function since pipeline is available for work
      assert Agent.get(dispatch_called, & &1) == true
    end

    test "handle_broadcast_status_cast/1 maintains state unchanged" do
      state = %{pipeline: PipelineStateMachine.new(:crf_searcher), other_field: :value}

      assert {:noreply, [], returned_state} =
               PipelineStateMachine.handle_broadcast_status_cast(state)

      # State should be unchanged
      assert returned_state == state
    end

    test "handle_start_processing/1 returns updated state with processing pipeline" do
      running_pipeline = PipelineStateMachine.new(:encoder) |> PipelineStateMachine.resume()
      state = %{pipeline: running_pipeline}

      updated_state = PipelineStateMachine.handle_start_processing(state)

      assert PipelineStateMachine.get_state(updated_state.pipeline) == :processing
    end
  end

  describe "state_to_event/2 comprehensive mapping" do
    test "maps all analyzer states correctly" do
      assert PipelineStateMachine.state_to_event(:analyzer, :stopped) == :analyzer_stopped
      assert PipelineStateMachine.state_to_event(:analyzer, :idle) == :analyzer_idle
      assert PipelineStateMachine.state_to_event(:analyzer, :running) == :analyzer_started
      assert PipelineStateMachine.state_to_event(:analyzer, :processing) == :analyzer_started
      assert PipelineStateMachine.state_to_event(:analyzer, :pausing) == :analyzer_pausing
      assert PipelineStateMachine.state_to_event(:analyzer, :paused) == :analyzer_paused
    end

    test "maps all crf_searcher states correctly" do
      assert PipelineStateMachine.state_to_event(:crf_searcher, :stopped) == :crf_searcher_stopped
      assert PipelineStateMachine.state_to_event(:crf_searcher, :idle) == :crf_searcher_idle
      assert PipelineStateMachine.state_to_event(:crf_searcher, :running) == :crf_searcher_started

      assert PipelineStateMachine.state_to_event(:crf_searcher, :processing) ==
               :crf_searcher_started

      assert PipelineStateMachine.state_to_event(:crf_searcher, :pausing) == :crf_searcher_pausing
      assert PipelineStateMachine.state_to_event(:crf_searcher, :paused) == :crf_searcher_paused
    end

    test "maps all encoder states correctly" do
      assert PipelineStateMachine.state_to_event(:encoder, :stopped) == :encoder_stopped
      assert PipelineStateMachine.state_to_event(:encoder, :idle) == :encoder_idle
      assert PipelineStateMachine.state_to_event(:encoder, :running) == :encoder_started
      assert PipelineStateMachine.state_to_event(:encoder, :processing) == :encoder_started
      assert PipelineStateMachine.state_to_event(:encoder, :pausing) == :encoder_pausing
      assert PipelineStateMachine.state_to_event(:encoder, :paused) == :encoder_paused
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
      assert_receive {:crf_searcher, :started}, 100
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
      assert_receive {:encoder, :started}, 100
    end
  end

  describe "comprehensive valid_transition?/2 testing" do
    test "validates all defined transitions" do
      # Test all valid transitions from each state
      valid_transitions = %{
        stopped: [:idle, :running, :paused],
        idle: [:running, :processing, :paused, :stopped],
        running: [:processing, :idle, :pausing, :paused, :stopped],
        processing: [:idle, :running, :pausing, :stopped],
        pausing: [:paused, :stopped],
        paused: [:running, :idle, :stopped]
      }

      for {from_state, to_states} <- valid_transitions do
        for to_state <- to_states do
          assert PipelineStateMachine.valid_transition?(from_state, to_state),
                 "Expected #{from_state} -> #{to_state} to be valid"
        end
      end
    end

    test "rejects invalid transitions" do
      # Test some known invalid transitions
      invalid_transitions = [
        {:stopped, :processing},
        {:paused, :processing},
        {:idle, :pausing},
        {:stopped, :pausing},
        {:paused, :pausing}
      ]

      for {from_state, to_state} <- invalid_transitions do
        refute PipelineStateMachine.valid_transition?(from_state, to_state),
               "Expected #{from_state} -> #{to_state} to be invalid"
      end
    end

    test "handles invalid states" do
      refute PipelineStateMachine.valid_transition?(:invalid_state, :running)
      refute PipelineStateMachine.valid_transition?(:running, :invalid_state)
      refute PipelineStateMachine.valid_transition?(:invalid, :also_invalid)
    end
  end

  describe "edge cases and error handling" do
    test "handles nil states gracefully in query functions" do
      # Test that invalid state atoms raise function clause errors due to guard clauses
      assert_raise FunctionClauseError, fn ->
        PipelineStateMachine.running?(:invalid_state)
      end

      assert_raise FunctionClauseError, fn ->
        PipelineStateMachine.actively_working?(:invalid_state)
      end

      assert_raise FunctionClauseError, fn ->
        PipelineStateMachine.available_for_work?(:invalid_state)
      end
    end

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

  describe "broadcasting functions" do
    setup do
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, "analyzer")
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, "crf_searcher")
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, "encoder")
      :ok
    end

    test "broadcast_state_transition/3 sends correct events" do
      PipelineStateMachine.broadcast_state_transition(:analyzer, :paused, :running)
      assert_receive {:analyzer, :started}, 100

      PipelineStateMachine.broadcast_state_transition(:crf_searcher, :running, :paused)
      assert_receive {:crf_searcher, :paused}, 100

      PipelineStateMachine.broadcast_state_transition(:encoder, :idle, :processing)
      assert_receive {:encoder, :started}, 100
    end
  end

  # Keep existing tests below
  describe "valid_states/0" do
    test "returns all valid pipeline states" do
      states = PipelineStateMachine.valid_states()

      assert :stopped in states
      assert :idle in states
      assert :running in states
      assert :processing in states
      assert :pausing in states
      assert :paused in states
      assert length(states) == 6
    end
  end

  describe "valid_transitions/1" do
    test "returns correct transitions from stopped state" do
      transitions = PipelineStateMachine.valid_transitions(:stopped)
      assert transitions == [:idle, :running, :paused]
    end

    test "returns correct transitions from idle state" do
      transitions = PipelineStateMachine.valid_transitions(:idle)
      assert transitions == [:running, :processing, :paused, :stopped]
    end

    test "returns correct transitions from running state" do
      transitions = PipelineStateMachine.valid_transitions(:running)
      assert transitions == [:processing, :idle, :pausing, :paused, :stopped]
    end

    test "returns correct transitions from processing state" do
      transitions = PipelineStateMachine.valid_transitions(:processing)
      assert transitions == [:idle, :running, :pausing, :stopped]
    end

    test "returns correct transitions from pausing state" do
      transitions = PipelineStateMachine.valid_transitions(:pausing)
      assert transitions == [:paused, :stopped]
    end

    test "returns correct transitions from paused state" do
      transitions = PipelineStateMachine.valid_transitions(:paused)
      assert transitions == [:running, :idle, :stopped]
    end

    test "returns empty list for invalid states" do
      assert PipelineStateMachine.valid_transitions(:invalid) == []
      assert PipelineStateMachine.valid_transitions(nil) == []
    end
  end

  describe "transition/2" do
    test "allows valid transitions" do
      assert {:ok, :running} = PipelineStateMachine.transition(:idle, :running)
      assert {:ok, :processing} = PipelineStateMachine.transition(:running, :processing)
      assert {:ok, :paused} = PipelineStateMachine.transition(:running, :paused)
    end

    test "rejects invalid transitions" do
      assert {:error, _} = PipelineStateMachine.transition(:stopped, :processing)
      assert {:error, _} = PipelineStateMachine.transition(:paused, :processing)
    end
  end

  describe "initial_state/0" do
    test "returns paused as initial state" do
      assert PipelineStateMachine.initial_state() == :paused
    end
  end

  describe "actively_working?/1" do
    test "returns true for processing state" do
      assert PipelineStateMachine.actively_working?(:processing)
    end

    test "returns false for non-processing states" do
      refute PipelineStateMachine.actively_working?(:idle)
      refute PipelineStateMachine.actively_working?(:paused)
    end
  end

  describe "available_for_work?/1" do
    test "returns true for states that can accept work" do
      assert PipelineStateMachine.available_for_work?(:idle)
      assert PipelineStateMachine.available_for_work?(:running)
    end

    test "returns false for states that cannot accept work" do
      refute PipelineStateMachine.available_for_work?(:processing)
      refute PipelineStateMachine.available_for_work?(:paused)
    end
  end

  describe "running?/1" do
    test "returns true for running-related states" do
      assert PipelineStateMachine.running?(:idle)
      assert PipelineStateMachine.running?(:running)
      assert PipelineStateMachine.running?(:processing)
    end

    test "returns false for stopped/paused states" do
      refute PipelineStateMachine.running?(:stopped)
      refute PipelineStateMachine.running?(:paused)
    end
  end

  describe "state_to_event/2" do
    test "maps pipeline states to correct dashboard events" do
      assert PipelineStateMachine.state_to_event(:analyzer, :running) == :analyzer_started
      assert PipelineStateMachine.state_to_event(:crf_searcher, :paused) == :crf_searcher_paused
      assert PipelineStateMachine.state_to_event(:encoder, :idle) == :encoder_idle
    end
  end

  describe "broadcast integration" do
    setup do
      # Subscribe to events to test broadcasting
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, "analyzer")
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, "crf_searcher")
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, "encoder")
      :ok
    end

    test "transition_with_broadcast performs transition and broadcasts events" do
      assert {:ok, :running} =
               PipelineStateMachine.transition_with_broadcast(:analyzer, :idle, :running)

      # Should receive PubSub message
      assert_receive {:analyzer, :started}, 100
    end

    test "handle_pause_with_broadcast transitions and broadcasts" do
      assert {:ok, :paused} =
               PipelineStateMachine.handle_pause_with_broadcast(:crf_searcher, :idle)

      # Should receive PubSub message
      assert_receive {:crf_searcher, :paused}, 100
    end

    test "handle_resume_with_broadcast transitions and broadcasts" do
      assert {:ok, :running} =
               PipelineStateMachine.handle_resume_with_broadcast(:encoder, :paused)

      # Should receive PubSub message
      assert_receive {:encoder, :started}, 100
    end
  end

  describe "producer integration functions" do
    test "handle_producer_pause_cast returns proper GenStage response" do
      state = %{status: :running, other_field: :value}

      assert {:noreply, [], new_state} =
               PipelineStateMachine.handle_producer_pause_cast(:analyzer, state)

      assert new_state.status == :paused
      assert new_state.other_field == :value
    end

    test "handle_producer_resume_cast calls dispatch function" do
      state = %{status: :paused}
      {:ok, dispatch_called} = Agent.start_link(fn -> false end)

      dispatch_func = fn new_state ->
        Agent.update(dispatch_called, fn _ -> true end)
        {:noreply, [], new_state}
      end

      assert {:noreply, [], _new_state} =
               PipelineStateMachine.handle_producer_resume_cast(
                 :crf_searcher,
                 state,
                 dispatch_func
               )

      # Dispatch function should have been called
      assert Agent.get(dispatch_called, & &1) == true
    end

    test "handle_producer_broadcast_status_cast maintains state" do
      state = %{status: :running, other_field: :value}

      assert {:noreply, [], returned_state} =
               PipelineStateMachine.handle_producer_broadcast_status_cast(:analyzer, state)

      # State should be unchanged
      assert returned_state == state
    end
  end
end
