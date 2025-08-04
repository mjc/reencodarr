defmodule Reencodarr.Services.ApiClient do
  @moduledoc """
  Generic API client module that provides common functionality for Sonarr/Radarr services.

  Eliminates code duplication between Sonarr and Radarr service modules by providing
  a shared foundation with consistent error handling, retry logic, and request patterns.
  """

  require Logger

  @doc """
  Creates a configured CarReq client with standard settings.
  """
  defmacro __using__(opts) do
    service_name = Keyword.get(opts, :service_name)
    config_getter = Keyword.get(opts, :config_getter)

    if !(service_name && config_getter) do
      raise ArgumentError, "Must provide :service_name and :config_getter options"
    end

    quote do
      require Logger
      alias Reencodarr.Services

      use CarReq,
        pool_timeout: 100,
        receive_timeout: 9_000,
        retry: :safe_transient,
        max_retries: 3,
        fuse_opts: {{:standard, 5, 30_000}, {:reset, 60_000}}

      def client_options do
        case unquote(config_getter).() do
          {:ok, %{url: url, api_key: api_key}} ->
            [base_url: url, headers: ["X-Api-Key": api_key]]

          {:error, :not_found} ->
            Logger.error("#{unquote(service_name)} config not found")
            []
        end
      end

      def system_status do
        request(url: "/api/v3/system/status", method: :get)
      end

      # Import common functionality
      import Reencodarr.Services.ApiClient,
        only: [
          handle_response: 1,
          log_request: 2,
          format_error: 2
        ]
    end
  end

  @doc """
  Handles common response patterns from API requests.
  """
  def handle_response({:ok, %{status: status} = response}) when status in 200..299 do
    {:ok, response}
  end

  def handle_response({:ok, %{status: status, body: body} = response}) do
    Logger.warning("API request failed with status #{status}: #{inspect(body)}")
    {:error, {:http_error, status, response}}
  end

  def handle_response({:error, reason} = error) do
    Logger.error("API request failed: #{inspect(reason)}")
    error
  end

  @doc """
  Logs API requests for debugging purposes.
  """
  def log_request(method, url) do
    Logger.debug("Making #{String.upcase(to_string(method))} request to #{url}")
  end

  @doc """
  Formats errors in a consistent way across services.
  """
  def format_error(service_name, reason) do
    "#{service_name} API error: #{inspect(reason)}"
  end

  @doc """
  Common file operations that both services support.
  """
  defmacro define_file_operations(item_type, _item_id_field) do
    quote do
      unquote(define_refresh_operation(item_type))
      unquote(define_rename_operation(item_type))
    end
  end

  # Separate macro for refresh operation
  defp define_refresh_operation(item_type) do
    quote do
      @spec refresh_item(integer()) :: {:ok, Req.Response.t()} | {:error, any()}
      def refresh_item(item_id) do
        {command_name, params} =
          case unquote(item_type) do
            :series -> {"RefreshSeries", %{name: "RefreshSeries", seriesIds: [item_id]}}
            :movie -> {"RefreshMovie", %{name: "RefreshMovie", movieIds: [item_id]}}
          end

        request(url: "/api/v3/command", method: :post, json: params)
      end
    end
  end

  # Separate macro for rename operation
  defp define_rename_operation(item_type) do
    quote do
      @spec rename_item_files(integer() | nil) :: {:ok, Req.Response.t()} | {:error, any()}
      def rename_item_files(item_id \\ nil) do
        params =
          case {unquote(item_type), item_id} do
            {:series, nil} -> %{name: "RenameFiles"}
            {:series, id} -> %{name: "RenameFiles", seriesId: id}
            {:movie, nil} -> %{name: "RenameFiles"}
            {:movie, id} -> %{name: "RenameFiles", movieId: id}
          end

        request(url: "/api/v3/command", method: :post, json: params)
      end
    end
  end

  @doc """
  Common patterns for getting items and files.
  """
  defmacro define_get_operations(item_type, _file_type) do
    quote do
      if unquote(item_type) == :series do
        @spec get_items() :: {:ok, Req.Response.t()} | {:error, any()}
        def get_items do
          request(url: "/api/v3/series?includeSeasonImages=false", method: :get)
        end

        @spec get_files(integer()) :: {:ok, Req.Response.t()} | {:error, any()}
        def get_files(series_id) do
          request(url: "/api/v3/episodefile?seriesId=#{series_id}", method: :get)
        end

        @spec get_file(integer()) :: {:ok, Req.Response.t()} | {:error, any()}
        def get_file(episode_file_id) do
          request(url: "/api/v3/episodefile/#{episode_file_id}", method: :get)
        end
      else
        @spec get_items() :: {:ok, Req.Response.t()} | {:error, any()}
        def get_items do
          request(url: "/api/v3/movie?includeImages=false", method: :get)
        end

        @spec get_files(integer()) :: {:ok, Req.Response.t()} | {:error, any()}
        def get_files(movie_id) do
          request(url: "/api/v3/moviefile?movieId=#{movie_id}", method: :get)
        end

        @spec get_file(integer()) :: {:ok, Req.Response.t()} | {:error, any()}
        def get_file(movie_file_id) do
          request(url: "/api/v3/moviefile/#{movie_file_id}", method: :get)
        end
      end
    end
  end
end
