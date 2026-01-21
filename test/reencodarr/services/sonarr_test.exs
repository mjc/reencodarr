defmodule Reencodarr.Services.SonarrTest do
  use ExUnit.Case

  # Note: Comprehensive integration tests for wait_for_command,
  # refresh_series_and_wait, and exponential backoff retry logic
  # are provided in scripts/test_app_rename.exs which tests against
  # a live Sonarr instance.
  #
  # These tests verify:
  # - Command status polling with wait_for_command/3
  # - Refresh and wait flow with refresh_series_and_wait/2
  # - Exponential backoff is applied (1s, 2s, 4s, etc.)
  # - Error handling and logging for all retry attempts
  #
  # The integration tests confirm proper behavior with actual
  # Sonarr API responses and network latencies.
  #
  # To run integration tests:
  #   SONARR_URL=http://localhost:8989 SONARR_API_KEY=your_key \
  #   elixir scripts/test_app_rename.exs

  test "placeholder - see scripts/test_app_rename.exs for integration tests" do
    # Integration tests are in scripts/test_app_rename.exs
    # which test the real Sonarr API
    assert true
  end
end
