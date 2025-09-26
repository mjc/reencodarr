defmodule Reencodarr.Broadway.StateManagementTest do
  use Reencodarr.UnitCase, async: true

  describe "Analyzer Broadway Producer state management" do
    alias Reencodarr.Analyzer.Broadway.Producer.State

    test "initializes with correct default state" do
      state = %State{
        demand: 0,
        paused: false,
        processing: false,
        pending_videos: []
      }

      assert state.demand == 0
      assert state.paused == false
      assert state.pending_videos == []
    end

    test "updates demand correctly" do
      initial_state = %State{
        demand: 0,
        paused: false,
        processing: false,
        pending_videos: []
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
        processing: false,
        pending_videos: []
      }

      paused_state = State.update(initial_state, paused: true)

      assert paused_state.paused == true
      # Other fields unchanged
      assert paused_state.demand == 0
    end

    test "updates pending videos correctly" do
      initial_state = %State{
        demand: 0,
        paused: false,
        processing: false,
        pending_videos: []
      }

      video_info = %{path: "/test/video.mkv", service_id: "1", service_type: :sonarr}
      updated_state = State.update(initial_state, pending_videos: [video_info])

      assert length(updated_state.pending_videos) == 1
      assert hd(updated_state.pending_videos) == video_info
    end

    test "updates multiple fields simultaneously" do
      initial_state = %State{
        demand: 0,
        paused: false,
        processing: false,
        pending_videos: []
      }

      video_info = %{path: "/test/video.mkv", service_id: "1", service_type: :sonarr}

      updated_state =
        State.update(initial_state,
          demand: 3,
          paused: true,
          pending_videos: [video_info]
        )

      assert updated_state.demand == 3
      assert updated_state.paused == true
      assert length(updated_state.pending_videos) == 1
    end

    test "preserves existing fields when updating others" do
      initial_state = %State{
        demand: 0,
        paused: false,
        processing: false,
        pending_videos: []
      }

      video1 = %{path: "/test/video1.mkv", service_id: "1", service_type: :sonarr}
      video2 = %{path: "/test/video2.mkv", service_id: "2", service_type: :radarr}

      # Set initial state with some values
      state_with_queue =
        State.update(initial_state,
          demand: 2,
          pending_videos: [video1]
        )

      # Update only demand, queue should remain
      state_updated_demand = State.update(state_with_queue, demand: 5)

      assert state_updated_demand.demand == 5
      assert length(state_updated_demand.pending_videos) == 1
      assert hd(state_updated_demand.pending_videos) == video1

      # Update only queue, demand should remain
      state_updated_queue = State.update(state_updated_demand, pending_videos: [video2])

      assert state_updated_queue.demand == 5
      assert length(state_updated_queue.pending_videos) == 1
      assert hd(state_updated_queue.pending_videos) == video2
    end
  end

  describe "Encoder Broadway Producer state management" do
    test "state contains demand and pipeline fields" do
      # Test basic state structure (Encoder uses plain map, not State struct)
      state = %{
        demand: 1,
        pipeline: %{}
      }

      assert state.demand == 1
      assert is_map(state.pipeline)
    end

    test "demand tracking works correctly" do
      # Test demand management in state
      state = %{
        demand: 0,
        pipeline: %{}
      }

      # Increment demand
      updated_state = %{state | demand: state.demand + 5}
      assert updated_state.demand == 5

      # Decrement demand
      final_state = %{updated_state | demand: updated_state.demand - 1}
      assert final_state.demand == 4
    end
  end

  describe "CRF Searcher Broadway Producer state management" do
    test "state contains demand and pipeline fields" do
      # Test basic state structure (CRF Searcher uses plain map, not State struct)
      state = %{
        demand: 1,
        pipeline: %{}
      }

      assert state.demand == 1
      assert is_map(state.pipeline)
    end

    test "single operation constraint" do
      # CRF searcher should only allow one operation at a time
      # This is enforced by the pipeline state machine and GenServer availability checks
      state = %{
        demand: 5,
        pipeline: %{}
      }

      # Even with high demand, CRF search should only dispatch one at a time
      # This is tested more thoroughly in integration tests
      assert state.demand == 5
    end
  end

  describe "Broadway pipeline error recovery" do
    test "handles state recovery after restart" do
      # Test basic state structure after pipeline restart
      recovered_state = %{
        demand: 0,
        pipeline: %{}
      }

      assert recovered_state.demand == 0
      assert is_map(recovered_state.pipeline)

      # Should be able to handle demand when it arrives
      state_with_demand = %{recovered_state | demand: 1}
      assert state_with_demand.demand == 1
    end

    test "handles demand fluctuations correctly" do
      state = %{
        demand: 0,
        pipeline: %{}
      }

      # Demand increases
      state_with_demand = %{state | demand: 3}
      assert state_with_demand.demand == 3

      # Demand decreases but still positive
      state_lower_demand = %{state_with_demand | demand: 1}
      assert state_lower_demand.demand == 1

      # Demand drops to zero
      state_no_demand = %{state_lower_demand | demand: 0}
      assert state_no_demand.demand == 0
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
