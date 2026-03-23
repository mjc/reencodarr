defmodule Reencodarr.Services.RadarrTest do
  use Reencodarr.DataCase, async: true

  alias Reencodarr.Services.Radarr

  setup do
    :meck.unload()
    :ok
  end

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

  describe "client_options/0 with config" do
    import Reencodarr.ServicesFixtures

    test "returns base_url and api_key headers when radarr config exists" do
      config_fixture(%{service_type: :radarr, url: "http://radarr.test", api_key: "secret"})
      opts = Radarr.client_options()
      assert Keyword.get(opts, :base_url) == "http://radarr.test"
      headers = Keyword.get(opts, :headers, [])
      assert Keyword.get(headers, :"X-Api-Key") == "secret"
    end
  end

  describe "rename_movie_files/1 guard clauses" do
    test "returns error for nil movie_id" do
      assert {:error, {:nil_value, "Movie ID"}} = Radarr.rename_movie_files(nil)
    end

    test "raises FunctionClauseError for string movie_id" do
      assert_raise FunctionClauseError, fn -> Radarr.rename_movie_files("123") end
    end

    test "raises FunctionClauseError for atom movie_id" do
      assert_raise FunctionClauseError, fn -> Radarr.rename_movie_files(:some_id) end
    end
  end

  describe "movie remediation helpers" do
    test "get_movie/1 requests a movie by id" do
      :meck.new(Radarr, [:passthrough])

      :meck.expect(Radarr, :api_request, fn opts ->
        assert opts[:method] == :get
        assert opts[:url] == "/api/v3/movie/77"
        {:ok, %{body: %{"id" => 77}}}
      end)

      assert {:ok, %{body: %{"id" => 77}}} = Radarr.get_movie(77)
    end

    test "set_movie_monitored/2 rejects nil movie ids" do
      assert Radarr.set_movie_monitored(nil, true) == {:error, :invalid_movie_id}
    end

    test "set_movie_monitored/2 updates monitored state via movie editor" do
      :meck.new(Radarr, [:passthrough])

      :meck.expect(Radarr, :api_request, fn opts ->
        assert opts[:method] == :put
        assert opts[:url] == "/api/v3/movie/editor"
        assert opts[:json] == %{movieIds: [77], monitored: true}
        {:ok, %{body: %{"updated" => true}}}
      end)

      assert {:ok, %{body: %{"updated" => true}}} = Radarr.set_movie_monitored(77, true)
    end

    test "delete_movie_file/1 rejects invalid movie file ids" do
      assert Radarr.delete_movie_file(nil) == {:error, :invalid_movie_file_id}
      assert Radarr.delete_movie_file("5") == {:error, :invalid_movie_file_id}
    end

    test "delete_movie_file/1 deletes a movie file by id" do
      :meck.new(Radarr, [:passthrough])

      :meck.expect(Radarr, :api_request, fn opts ->
        assert opts[:method] == :delete
        assert opts[:url] == "/api/v3/moviefile/88"
        {:ok, %{status: 200}}
      end)

      assert {:ok, %{status: 200}} = Radarr.delete_movie_file(88)
    end

    test "trigger_movie_search/1 rejects nil movie ids" do
      assert Radarr.trigger_movie_search(nil) == {:error, :invalid_movie_id}
    end

    test "trigger_movie_search/1 sends a MoviesSearch command" do
      :meck.new(Radarr, [:passthrough])

      :meck.expect(Radarr, :api_request, fn opts ->
        assert opts[:method] == :post
        assert opts[:url] == "/api/v3/command"
        assert opts[:json] == %{name: "MoviesSearch", movieIds: [77]}
        {:ok, %{body: %{"id" => 444}}}
      end)

      assert {:ok, %{body: %{"id" => 444}}} = Radarr.trigger_movie_search(77)
    end
  end
end
