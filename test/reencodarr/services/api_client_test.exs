defmodule Reencodarr.Services.ApiClientTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  alias Reencodarr.Services.ApiClient

  describe "handle_response/1 for success responses" do
    test "returns {:ok, response} for status 200" do
      response = %{status: 200, body: %{"ok" => true}}
      assert {:ok, ^response} = ApiClient.handle_response({:ok, response})
    end

    test "returns {:ok, response} for status 201" do
      response = %{status: 201, body: %{"created" => true}}
      assert {:ok, ^response} = ApiClient.handle_response({:ok, response})
    end

    test "returns {:ok, response} for status 204" do
      response = %{status: 204, body: nil}
      assert {:ok, ^response} = ApiClient.handle_response({:ok, response})
    end

    test "returns {:ok, response} for status 299" do
      response = %{status: 299, body: ""}
      assert {:ok, ^response} = ApiClient.handle_response({:ok, response})
    end
  end

  describe "handle_response/1 for error status codes" do
    test "returns {:error, {:http_error, status, response}} for 400" do
      response = %{status: 400, body: "Bad Request"}
      assert {:error, {:http_error, 400, ^response}} = ApiClient.handle_response({:ok, response})
    end

    test "returns {:error, {:http_error, status, response}} for 401" do
      response = %{status: 401, body: "Unauthorized"}
      assert {:error, {:http_error, 401, ^response}} = ApiClient.handle_response({:ok, response})
    end

    test "returns {:error, {:http_error, status, response}} for 404" do
      response = %{status: 404, body: "Not Found"}
      assert {:error, {:http_error, 404, ^response}} = ApiClient.handle_response({:ok, response})
    end

    test "returns {:error, {:http_error, status, response}} for 500" do
      response = %{status: 500, body: "Internal Server Error"}
      assert {:error, {:http_error, 500, ^response}} = ApiClient.handle_response({:ok, response})
    end
  end

  describe "handle_response/1 for connection errors" do
    test "returns the same {:error, reason} for network errors" do
      error = {:error, :econnrefused}
      assert {:error, :econnrefused} = ApiClient.handle_response(error)
    end

    test "returns {:error, reason} for timeout errors" do
      error = {:error, :timeout}
      assert {:error, :timeout} = ApiClient.handle_response(error)
    end
  end

  describe "format_error/2" do
    test "formats error as 'ServiceName API error: reason'" do
      result = ApiClient.format_error("Sonarr", :not_found)
      assert result == "Sonarr API error: :not_found"
    end

    test "formats string reason with inspect" do
      result = ApiClient.format_error("Radarr", "connection refused")
      assert result == ~s(Radarr API error: "connection refused")
    end

    test "formats complex reason with inspect" do
      result = ApiClient.format_error("Plex", {:http_error, 500, %{}})
      assert is_binary(result)
      assert String.starts_with?(result, "Plex API error:")
    end

    test "returns a string" do
      result = ApiClient.format_error("Test", :any_reason)
      assert is_binary(result)
    end
  end

  describe "log_request/2" do
    test "returns :ok" do
      assert :ok == ApiClient.log_request(:get, "http://example.com/api")
    end

    test "accepts atom method" do
      assert :ok == ApiClient.log_request(:post, "http://example.com/api/command")
    end

    test "accepts string method" do
      assert :ok == ApiClient.log_request("get", "http://example.com/api")
    end
  end
end
