defmodule Reencodarr.DashboardStateTest do
  use Reencodarr.DataCase

  alias Reencodarr.DashboardState
  alias Reencodarr.Statistics.Stats

  describe "initial/0" do
    test "creates initial dashboard state with proper stats structure" do
      state = DashboardState.initial()

      assert %DashboardState{} = state
      assert %Stats{} = state.stats

      # Verify all expected fields exist
      assert Map.has_key?(state.stats, :next_analyzer)
      assert Map.has_key?(state.stats, :next_crf_search)
      assert Map.has_key?(state.stats, :videos_by_estimated_percent)
      assert Map.has_key?(state.stats, :queue_length)

      # Verify default values
      assert is_list(state.stats.next_analyzer)
      assert is_list(state.stats.next_crf_search)
      assert is_list(state.stats.videos_by_estimated_percent)
      assert is_map(state.stats.queue_length)
    end

    test "handles incomplete Stats structs gracefully" do
      # Simulate a Stats struct that might be missing the next_analyzer field
      # This could happen if an old version of the struct is loaded from cache/DB
      incomplete_stats = %{
        total_videos: 100,
        queue_length: %{analyzer: 0, crf_searches: 0, encodes: 0},
        next_crf_search: [],
        videos_by_estimated_percent: []
        # Note: missing next_analyzer field
      }

      state = %DashboardState{stats: incomplete_stats}

      # This should not crash even if next_analyzer is missing
      # The presenter should handle it gracefully
      assert is_map(state.stats)
      refute Map.has_key?(state.stats, :next_analyzer)
    end
  end

  describe "update_queue_state/4" do
    setup do
      state = %DashboardState{
        stats: %Stats{
          queue_length: %{analyzer: 0, crf_searches: 0, encodes: 0},
          next_analyzer: [],
          next_crf_search: [],
          videos_by_estimated_percent: []
        }
      }

      {:ok, state: state}
    end

    test "updates analyzer queue state and preserves struct type", %{state: state} do
      measurements = %{queue_size: 5}
      metadata = %{next_videos: [%{id: 1}, %{id: 2}]}

      new_state = DashboardState.update_queue_state(state, :analyzer, measurements, metadata)

      assert %DashboardState{stats: %Stats{}} = new_state
      assert new_state.stats.queue_length.analyzer == 5
      assert new_state.stats.next_analyzer == [%{id: 1}, %{id: 2}]

      # Verify the struct still has all expected fields
      assert Map.has_key?(new_state.stats, :next_analyzer)
      assert Map.has_key?(new_state.stats, :next_crf_search)
      assert Map.has_key?(new_state.stats, :videos_by_estimated_percent)
    end

    test "updates crf_searcher queue state and preserves struct type", %{state: state} do
      measurements = %{queue_size: 10}
      metadata = %{next_videos: [%{id: 3}, %{id: 4}]}

      new_state = DashboardState.update_queue_state(state, :crf_searcher, measurements, metadata)

      assert %DashboardState{stats: %Stats{}} = new_state
      assert new_state.stats.queue_length.crf_searches == 10
      assert new_state.stats.next_crf_search == [%{id: 3}, %{id: 4}]

      # Verify the struct still has all expected fields
      assert Map.has_key?(new_state.stats, :next_analyzer)
      assert Map.has_key?(new_state.stats, :next_crf_search)
      assert Map.has_key?(new_state.stats, :videos_by_estimated_percent)
    end

    test "updates encoder queue state and preserves struct type", %{state: state} do
      measurements = %{queue_size: 2}
      metadata = %{next_vmafs: [%{id: 5}, %{id: 6}]}

      new_state = DashboardState.update_queue_state(state, :encoder, measurements, metadata)

      assert %DashboardState{stats: %Stats{}} = new_state
      assert new_state.stats.queue_length.encodes == 2
      assert new_state.stats.videos_by_estimated_percent == [%{id: 5}, %{id: 6}]

      # Verify the struct still has all expected fields
      assert Map.has_key?(new_state.stats, :next_analyzer)
      assert Map.has_key?(new_state.stats, :next_crf_search)
      assert Map.has_key?(new_state.stats, :videos_by_estimated_percent)
    end

    test "handles unknown queue types gracefully", %{state: state} do
      measurements = %{queue_size: 99}
      metadata = %{some_data: "test"}

      new_state = DashboardState.update_queue_state(state, :unknown, measurements, metadata)

      # Should return unchanged state
      assert new_state == state
    end
  end

  describe "significant_change?/2" do
    test "detects significant changes in queue lengths" do
      old_state = %DashboardState{
        stats: %Stats{
          queue_length: %{analyzer: 0, crf_searches: 0, encodes: 0},
          next_analyzer: []
        }
      }

      new_state = %DashboardState{
        stats: %Stats{
          queue_length: %{analyzer: 5, crf_searches: 0, encodes: 0},
          next_analyzer: [%{id: 1}]
        }
      }

      assert DashboardState.significant_change?(old_state, new_state)
    end

    test "detects no significant change when queues are the same" do
      state = %DashboardState{
        stats: %Stats{
          queue_length: %{analyzer: 5, crf_searches: 0, encodes: 0},
          next_analyzer: [%{id: 1}]
        }
      }

      refute DashboardState.significant_change?(state, state)
    end
  end
end
