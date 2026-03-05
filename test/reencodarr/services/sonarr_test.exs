defmodule Reencodarr.Services.SonarrTest do
  use Reencodarr.DataCase, async: true

  alias Reencodarr.Services.Sonarr

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

  describe "client_options/0" do
    test "returns empty list when Sonarr config is not configured" do
      # No config seeded in test DB — expects empty list and logs error
      assert Sonarr.client_options() == []
    end

    test "returns base_url and api_key headers when sonarr config exists" do
      import Reencodarr.ServicesFixtures

      config_fixture(%{
        service_type: :sonarr,
        url: "http://sonarr.test",
        api_key: "sonarr_secret"
      })

      opts = Sonarr.client_options()
      assert Keyword.get(opts, :base_url) == "http://sonarr.test"
      headers = Keyword.get(opts, :headers, [])
      assert Keyword.get(headers, :"X-Api-Key") == "sonarr_secret"
    end
  end

  describe "rename_files/1 guard clauses" do
    test "returns error for non-integer string series_id" do
      assert Sonarr.rename_files("abc") == {:error, :invalid_series_id}
    end

    test "returns error for non-integer atom series_id" do
      assert Sonarr.rename_files(:some_id) == {:error, :invalid_series_id}
    end

    test "returns error for nil series_id" do
      assert Sonarr.rename_files(nil) == {:error, :invalid_series_id}
    end

    test "returns error for zero series_id" do
      assert Sonarr.rename_files(0) == {:error, :invalid_series_id}
    end

    test "returns error for negative series_id" do
      assert Sonarr.rename_files(-1) == {:error, :invalid_series_id}
    end

    test "returns error for large negative series_id" do
      assert Sonarr.rename_files(-9999) == {:error, :invalid_series_id}
    end
  end
end
