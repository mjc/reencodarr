defmodule ReencodarrWeb.Dashboard.PresenterTest do
  use Reencodarr.DataCase

  alias Reencodarr.DashboardState
  alias Reencodarr.Statistics.Stats
  alias ReencodarrWeb.Dashboard.Presenter

  describe "present/1" do
    test "handles DashboardState with complete Stats struct" do
      state = %DashboardState{
        stats: %Stats{
          total_videos: 100,
          queue_length: %{analyzer: 5, crf_searches: 10, encodes: 2},
          next_analyzer: [%{id: 1}, %{id: 2}],
          next_crf_search: [%{id: 3}],
          videos_by_estimated_percent: [%{id: 4}]
        },
        analyzing: true,
        crf_searching: false,
        encoding: false,
        syncing: false
      }

      result = Presenter.present(state)

      assert is_map(result)
      assert Map.has_key?(result, :queues)
      assert Map.has_key?(result.queues, :analyzer)
      # The analyzer queue should be properly created
      assert is_map(result.queues.analyzer)
      assert is_list(result.queues.analyzer.files)
    end

    test "handles DashboardState with incomplete Stats struct (missing next_analyzer)" do
      # Create a proper Stats struct but simulate missing next_analyzer in a different way
      # Instead of testing with invalid struct, test the defensive presenter handling
      state = %DashboardState{
        stats: %Stats{
          total_videos: 100,
          queue_length: %{analyzer: 5, crf_searches: 10, encodes: 2},
          # Empty list simulates no analyzer files
          next_analyzer: [],
          next_crf_search: [%{id: 3}],
          videos_by_estimated_percent: [%{id: 4}]
        },
        analyzing: true,
        crf_searching: false,
        encoding: false,
        syncing: false
      }

      # This should not crash and should handle empty analyzer queue gracefully
      result = Presenter.present(state)

      assert is_map(result)
      assert Map.has_key?(result, :queues)
      assert Map.has_key?(result.queues, :analyzer)
      # Should handle empty analyzer files gracefully
      assert is_list(result.queues.analyzer.files)
    end

    test "handles simple state gracefully" do
      # Use a minimal valid DashboardState
      state = %DashboardState{
        stats: %Stats{},
        analyzing: false,
        crf_searching: false,
        encoding: false,
        syncing: false
      }

      result = Presenter.present(state)
      assert is_map(result)
      assert Map.has_key?(result, :metrics)
      assert Map.has_key?(result, :status)
      assert Map.has_key?(result, :queues)
      assert Map.has_key?(result, :stats)
    end
  end
end
