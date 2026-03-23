defmodule Reencodarr.Services.SonarrTest do
  use Reencodarr.DataCase, async: true

  alias Reencodarr.Services.Sonarr

  setup do
    :meck.unload()
    :ok
  end

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

  describe "episode remediation helpers" do
    test "get_episodes_by_file/1 requests episodes for an episode file id" do
      :meck.new(Sonarr, [:passthrough])

      :meck.expect(Sonarr, :api_request, fn opts ->
        assert opts[:method] == :get
        assert opts[:url] == "/api/v3/episode?episodeFileId=42"
        {:ok, %{body: [%{"id" => 101}]}}
      end)

      assert {:ok, %{body: [%{"id" => 101}]}} = Sonarr.get_episodes_by_file(42)
    end

    test "set_episodes_monitored/2 rejects empty episode id lists" do
      assert Sonarr.set_episodes_monitored([], true) == {:error, :invalid_episode_ids}
    end

    test "set_episodes_monitored/2 updates monitor state for episode ids" do
      :meck.new(Sonarr, [:passthrough])

      :meck.expect(Sonarr, :api_request, fn opts ->
        assert opts[:method] == :put
        assert opts[:url] == "/api/v3/episode/monitor"
        assert opts[:json] == %{episodeIds: [101, 102], monitored: true}
        {:ok, %{body: %{"updated" => true}}}
      end)

      assert {:ok, %{body: %{"updated" => true}}} =
               Sonarr.set_episodes_monitored([101, 102], true)
    end

    test "delete_episode_file/1 rejects invalid file ids" do
      assert Sonarr.delete_episode_file(nil) == {:error, :invalid_episode_file_id}
      assert Sonarr.delete_episode_file("1") == {:error, :invalid_episode_file_id}
    end

    test "delete_episode_file/1 deletes an episode file by id" do
      :meck.new(Sonarr, [:passthrough])

      :meck.expect(Sonarr, :api_request, fn opts ->
        assert opts[:method] == :delete
        assert opts[:url] == "/api/v3/episodefile/55"
        {:ok, %{status: 200}}
      end)

      assert {:ok, %{status: 200}} = Sonarr.delete_episode_file(55)
    end

    test "trigger_episode_search/1 rejects empty episode id lists" do
      assert Sonarr.trigger_episode_search([]) == {:error, :invalid_episode_ids}
    end

    test "trigger_episode_search/1 sends an EpisodeSearch command" do
      :meck.new(Sonarr, [:passthrough])

      :meck.expect(Sonarr, :api_request, fn opts ->
        assert opts[:method] == :post
        assert opts[:url] == "/api/v3/command"
        assert opts[:json] == %{name: "EpisodeSearch", episodeIds: [101, 102]}
        {:ok, %{body: %{"id" => 999}}}
      end)

      assert {:ok, %{body: %{"id" => 999}}} = Sonarr.trigger_episode_search([101, 102])
    end
  end
end
