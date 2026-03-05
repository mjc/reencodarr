defmodule Reencodarr.Services.RadarrTest do
  use Reencodarr.DataCase, async: true

  alias Reencodarr.Services.Radarr

  # Note: Comprehensive integration tests for wait_for_command,
  # refresh_movie_and_wait, and exponential backoff retry logic
  # are provided in scripts/test_app_rename.exs which tests against
  # a live Radarr instance.
  #
  # These tests verify:
  # - Command status polling with wait_for_command/3
  # - Refresh and wait flow with refresh_movie_and_wait/2
  # - Exponential backoff is applied (1s, 2s, 4s, etc.)
  # - Error handling and logging for all retry attempts
  #
  # The integration tests confirm proper behavior with actual
  # Radarr API responses and network latencies.
  #
  # To run integration tests:
  #   RADARR_URL=http://localhost:7878 RADARR_API_KEY=your_key \
  #   elixir scripts/test_app_rename.exs

  describe "client_options/0" do
    test "returns empty list when Radarr config is not configured" do
      # No config seeded in test DB — expects empty list and logs error
      assert Radarr.client_options() == []
    end
  end

  describe "rename_movie_files/1 guard clauses" do
    test "returns error for nil movie_id" do
      assert {:error, {:nil_value, "Movie ID"}} = Radarr.rename_movie_files(nil)
    end
  end
end
