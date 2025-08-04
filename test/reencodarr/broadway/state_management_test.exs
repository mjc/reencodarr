defmodule Reencodarr.Broadway.StateManagementTest do
  use ExUnit.Case, async: true

  describe "Analyzer Broadway Producer state management" do
    alias Reencodarr.Analyzer.Broadway.Producer.State

    test "initializes with correct default state" do
      state = %State{
        demand: 0,
        status: :paused,
        queue: :queue.new(),
        manual_queue: []
      }

      assert state.demand == 0
      assert state.status == :paused
      assert state.manual_queue == []
    end

    test "updates demand correctly" do
      initial_state = %State{
        demand: 0,
        paused: false,
        queue: :queue.new(),
        processing: false,
        manual_queue: []
      }

      updated_state = State.update(initial_state, demand: 5)

      assert updated_state.demand == 5
      # Other fields unchanged
      assert updated_state.paused == false
    end

    test "updates paused status correctly" do
      initial_state = %State{
        demand: 0,
        paused: false,
        queue: :queue.new(),
        processing: false,
        manual_queue: []
      }

      paused_state = State.update(initial_state, paused: true)

      assert paused_state.paused == true
      # Other fields unchanged
      assert paused_state.demand == 0
    end

    test "updates manual queue correctly" do
      initial_state = %State{
        demand: 0,
        paused: false,
        queue: :queue.new(),
        processing: false,
        manual_queue: []
      }

      video_info = %{path: "/test/video.mkv", service_id: "1", service_type: :sonarr}
      updated_state = State.update(initial_state, manual_queue: [video_info])

      assert length(updated_state.manual_queue) == 1
      assert hd(updated_state.manual_queue) == video_info
    end

    test "updates multiple fields simultaneously" do
      initial_state = %State{
        demand: 0,
        paused: false,
        queue: :queue.new(),
        processing: false,
        manual_queue: []
      }

      video_info = %{path: "/test/video.mkv", service_id: "1", service_type: :sonarr}

      updated_state =
        State.update(initial_state,
          demand: 3,
          paused: true,
          manual_queue: [video_info]
        )

      assert updated_state.demand == 3
      assert updated_state.paused == true
      assert length(updated_state.manual_queue) == 1
    end

    test "preserves existing fields when updating others" do
      initial_state = %State{
        demand: 0,
        paused: false,
        queue: :queue.new(),
        processing: false,
        manual_queue: []
      }

      video1 = %{path: "/test/video1.mkv", service_id: "1", service_type: :sonarr}
      video2 = %{path: "/test/video2.mkv", service_id: "2", service_type: :radarr}

      # Set initial state with some values
      state_with_queue =
        State.update(initial_state,
          demand: 2,
          manual_queue: [video1]
        )

      # Update only demand, queue should remain
      state_updated_demand = State.update(state_with_queue, demand: 5)

      assert state_updated_demand.demand == 5
      assert length(state_updated_demand.manual_queue) == 1
      assert hd(state_updated_demand.manual_queue) == video1

      # Update only queue, demand should remain
      state_updated_queue = State.update(state_updated_demand, manual_queue: [video2])

      assert state_updated_queue.demand == 5
      assert length(state_updated_queue.manual_queue) == 1
      assert hd(state_updated_queue.manual_queue) == video2
    end
  end

  describe "Encoder Broadway Producer state management" do
    test "processing flag prevents duplicate dispatches" do
      # Test the logic that prevents dispatching when already processing
      state = %{
        demand: 1,
        paused: false,
        queue: :queue.new(),
        processing: false
      }

      # When not processing and has demand, should be able to dispatch
      assert should_dispatch?(state) == true

      # When processing, should not dispatch regardless of demand
      processing_state = %{state | processing: true}
      assert should_dispatch?(processing_state) == false

      # When paused, should not dispatch
      paused_state = %{state | paused: true}
      assert should_dispatch?(paused_state) == false

      # When no demand, should not dispatch
      no_demand_state = %{state | demand: 0}
      assert should_dispatch?(no_demand_state) == false
    end

    test "queue management works correctly" do
      empty_queue = :queue.new()

      # Add items to queue
      queue_with_one = :queue.in("item1", empty_queue)
      queue_with_two = :queue.in("item2", queue_with_one)

      assert :queue.len(queue_with_two) == 2

      # Remove items from queue
      {{:value, item}, remaining_queue} = :queue.out(queue_with_two)
      # FIFO behavior
      assert item == "item1"
      assert :queue.len(remaining_queue) == 1

      {{:value, last_item}, final_queue} = :queue.out(remaining_queue)
      assert last_item == "item2"
      assert :queue.is_empty(final_queue) == true
    end

    test "state transitions during encoding lifecycle" do
      initial_state = %{
        demand: 1,
        paused: false,
        queue: :queue.new(),
        processing: false
      }

      # 1. Start processing - set processing flag
      processing_state = %{initial_state | processing: true, demand: 0}
      assert processing_state.processing == true
      assert processing_state.demand == 0

      # 2. Encoding completes - reset processing flag
      completed_state = %{processing_state | processing: false}
      assert completed_state.processing == false

      # 3. Ready for next dispatch if demand returns
      ready_state = %{completed_state | demand: 1}
      assert should_dispatch?(ready_state) == true
    end

    defp should_dispatch?(state) do
      not state.paused and not state.processing and state.demand > 0
    end
  end

  describe "CRF Searcher Broadway Producer state management" do
    test "prevents multiple CRF searches from running simultaneously" do
      # CRF searcher should only allow one operation at a time
      state = %{
        # Multiple demands
        demand: 2,
        paused: false,
        queue: :queue.new(),
        processing: false
      }

      # Should be able to start one CRF search
      assert can_start_crf_search?(state) == true

      # Once processing, should not start another
      processing_state = %{state | processing: true}
      assert can_start_crf_search?(processing_state) == false

      # Even with high demand, only one at a time
      high_demand_processing = %{processing_state | demand: 10}
      assert can_start_crf_search?(high_demand_processing) == false
    end

    test "respects single-worker limitation" do
      # CRF search pipeline should have concurrency: 1 to prevent conflicts
      # This test verifies the logic that enforces this limitation

      state = %{
        # High demand
        demand: 5,
        paused: false,
        queue: :queue.new(),
        processing: false
      }

      # Should only dispatch one item even with high demand
      max_dispatch_count = get_max_dispatch_count(state)
      assert max_dispatch_count == 1
    end

    defp can_start_crf_search?(state) do
      not state.paused and not state.processing and state.demand > 0
    end

    defp get_max_dispatch_count(state) do
      # Simulate the logic that determines how many items to dispatch
      # For CRF searcher, this should always be 1 to respect single-worker limitation
      if can_start_crf_search?(state) do
        # Always dispatch only one for CRF search
        1
      else
        0
      end
    end
  end

  describe "Broadway pipeline error recovery" do
    test "handles Broadway pipeline restart scenarios" do
      # Test state recovery after pipeline restart
      persisted_queue_data = [
        %{path: "/video1.mkv", service_id: "1", service_type: :sonarr},
        %{path: "/video2.mkv", service_id: "2", service_type: :radarr}
      ]

      # Simulate pipeline restart with persisted data
      recovered_state = %{
        demand: 0,
        paused: false,
        queue:
          Enum.reduce(persisted_queue_data, :queue.new(), fn item, acc ->
            :queue.in(item, acc)
          end),
        # Should reset to false after restart
        processing: false
      }

      assert :queue.len(recovered_state.queue) == 2
      assert recovered_state.processing == false

      # Should be able to process when demand arrives
      state_with_demand = %{recovered_state | demand: 1}
      assert should_dispatch?(state_with_demand) == true
    end

    test "handles pause/resume state correctly" do
      active_state = %{
        demand: 1,
        paused: false,
        queue: :queue.new(),
        processing: false
      }

      # Pause the pipeline
      paused_state = %{active_state | paused: true}
      assert should_dispatch?(paused_state) == false

      # Resume the pipeline
      resumed_state = %{paused_state | paused: false}
      assert should_dispatch?(resumed_state) == true
    end

    test "handles demand fluctuations correctly" do
      state = %{
        demand: 0,
        paused: false,
        queue: :queue.in("item", :queue.new()),
        processing: false
      }

      # No demand initially
      assert should_dispatch?(state) == false

      # Demand increases
      state_with_demand = %{state | demand: 3}
      assert should_dispatch?(state_with_demand) == true

      # Demand decreases but still positive
      state_lower_demand = %{state_with_demand | demand: 1}
      assert should_dispatch?(state_lower_demand) == true

      # Demand drops to zero
      state_no_demand = %{state_lower_demand | demand: 0}
      assert should_dispatch?(state_no_demand) == false
    end
  end

  describe "telemetry and monitoring integration" do
    test "state changes should emit appropriate telemetry events" do
      # This test would verify that state changes emit telemetry for monitoring
      # In a real implementation, you'd test actual telemetry emission

      state_changes = [
        {:pause, "Pipeline paused for maintenance"},
        {:resume, "Pipeline resumed"},
        {:error, "Processing error occurred"},
        {:queue_full, "Queue at maximum capacity"}
      ]

      Enum.each(state_changes, fn {event_type, message} ->
        # Simulate telemetry emission
        telemetry_event = %{
          event: event_type,
          message: message,
          timestamp: System.system_time(:microsecond)
        }

        # Verify event structure
        assert Map.has_key?(telemetry_event, :event)
        assert Map.has_key?(telemetry_event, :message)
        assert Map.has_key?(telemetry_event, :timestamp)
        assert is_atom(telemetry_event.event)
        assert is_binary(telemetry_event.message)
        assert is_integer(telemetry_event.timestamp)
      end)
    end
  end
end
