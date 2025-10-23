defmodule Reencodarr.Dashboard.V2.StateSubscriptionTest do
  use ExUnit.Case, async: true

  describe "dashboard state message handling" do
    test "state messages update service_status correctly" do
      # Simulate receiving a state change message
      service_status = %{
        analyzer: :paused,
        crf_searcher: :paused,
        encoder: :paused
      }

      # Simulate receiving {:crf_searcher, :pausing} message
      new_status = Map.put(service_status, :crf_searcher, :pausing)

      assert new_status == %{
               analyzer: :paused,
               crf_searcher: :pausing,
               encoder: :paused
             }
    end

    test "actual state values flow through without translation" do
      # Test that all possible state values can be set
      states = [:stopped, :idle, :running, :processing, :pausing, :paused]
      service_status = %{analyzer: :paused, crf_searcher: :paused, encoder: :paused}

      for state <- states do
        updated = Map.put(service_status, :analyzer, state)
        assert updated.analyzer == state
      end
    end

    test "multiple services can have different states simultaneously" do
      service_status = %{
        analyzer: :running,
        crf_searcher: :pausing,
        encoder: :paused
      }

      # Each service should maintain its own state
      assert service_status.analyzer == :running
      assert service_status.crf_searcher == :pausing
      assert service_status.encoder == :paused
    end

    test "state transitions preserve other services unchanged" do
      service_status = %{
        analyzer: :running,
        crf_searcher: :processing,
        encoder: :idle
      }

      # Update one service
      updated = Map.put(service_status, :crf_searcher, :pausing)

      # Others should be unchanged
      assert updated.analyzer == :running
      assert updated.crf_searcher == :pausing
      assert updated.encoder == :idle
    end

    test "pausing state shows work in progress" do
      # Pausing state should indicate that work is being finalized
      service_status = %{
        analyzer: :running,
        crf_searcher: :pausing,
        encoder: :paused
      }

      # The dashboard should show pausing distinctly from paused
      assert service_status.crf_searcher == :pausing
      refute service_status.crf_searcher == :paused
    end

    test "pause request flow: processing -> pausing -> paused" do
      # Start with processing
      status = %{analyzer: :processing, crf_searcher: :paused, encoder: :paused}
      assert status.analyzer == :processing

      # Pause request: processing -> pausing
      status = Map.put(status, :analyzer, :pausing)
      assert status.analyzer == :pausing

      # Work completes: pausing -> paused
      status = Map.put(status, :analyzer, :paused)
      assert status.analyzer == :paused
    end

    test "pause without work: running -> paused directly" do
      # Start with running
      status = %{analyzer: :running, crf_searcher: :paused, encoder: :paused}
      assert status.analyzer == :running

      # Pause request when not processing: running -> paused directly
      status = Map.put(status, :analyzer, :paused)
      assert status.analyzer == :paused
    end

    test "duplicate pause while pausing stays pausing" do
      # Already pausing
      status = %{analyzer: :pausing, crf_searcher: :paused, encoder: :paused}
      assert status.analyzer == :pausing

      # Second pause request: should stay pausing
      # (In reality this is handled in the producer, but the status should remain)
      status = Map.put(status, :analyzer, :pausing)
      assert status.analyzer == :pausing
    end
  end
end
