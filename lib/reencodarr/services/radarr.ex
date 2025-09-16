defmodule Reencodarr.Services.Radarr do
  @moduledoc """
  This module is responsible for communicating with the Radarr API.
  """
  require Logger
  alias Reencodarr.Core.Parsers
  alias Reencodarr.ErrorHelpers
  alias Reencodarr.Services

  use CarReq,
    pool_timeout: 100,
    receive_timeout: 9_000,
    retry: :safe_transient,
    max_retries: 3,
    fuse_opts: {{:standard, 5, 30_000}, {:reset, 60_000}}

  def client_options do
    case Services.get_radarr_config() do
      {:ok, %{url: url, api_key: api_key}} ->
        [base_url: url, headers: ["X-Api-Key": api_key]]

      {:error, :not_found} ->
        ErrorHelpers.config_not_found_error("Radarr")
        []
    end
  end

  @spec get_movies() :: {:ok, Req.Response.t()} | {:error, any()}
  def get_movies do
    request(url: "/api/v3/movie?includeImages=false", method: :get)
  end

  @spec get_movie_files(integer()) :: {:ok, Req.Response.t()} | {:error, any()}
  def get_movie_files(movie_id) do
    request(url: "/api/v3/moviefile?movieId=#{movie_id}", method: :get)
  end

  @spec get_movie_file(integer()) :: {:ok, Req.Response.t()} | {:error, any()}
  def get_movie_file(movie_file_id) do
    request(url: "/api/v3/moviefile/#{movie_file_id}", method: :get)
  end

  @spec refresh_movie(integer()) :: {:ok, Req.Response.t()} | {:error, any()}
  def refresh_movie(movie_id) do
    request(
      url: "/api/v3/command",
      method: :post,
      json: %{name: "RefreshMovie", movieIds: [movie_id]}
    )
  end

  @spec rename_movie_files(integer() | nil) :: {:ok, Req.Response.t()} | {:error, any()}
  def rename_movie_files(nil) do
    ErrorHelpers.handle_nil_value(nil, "Movie ID", "Cannot rename files")
  end

  def rename_movie_files(movie_id) do
    perform_movie_refresh(movie_id)

    # Give Radarr a moment to process the refresh
    Process.sleep(2000)

    get_radarr_renameable_files(movie_id)
    |> case do
      [] ->
        Logger.info("No files need renaming for movie ID: #{movie_id}")
        {:ok, %{message: "No files need renaming"}}

      files ->
        execute_movie_rename(movie_id, files)
    end
  end

  defp perform_movie_refresh(movie_id) do
    Logger.info("Refreshing movie ID: #{movie_id} before checking for renameable files")

    ErrorHelpers.handle_error_with_warning(
      refresh_movie(movie_id),
      :ok,
      "Failed to refresh movie"
    )
  end

  defp get_radarr_renameable_files(movie_id) do
    Logger.info("Checking renameable files for movie ID: #{movie_id}")

    request(url: "/api/v3/rename?movieId=#{movie_id}", method: :get)
    |> ErrorHelpers.handle_error_with_default([], "Failed to get renameable files")
    |> case do
      [] ->
        []

      resp when is_map(resp) ->
        Logger.debug("Renameable files response: #{inspect(resp.body)}")
        resp.body

      other ->
        other
    end
  end

  @spec execute_movie_rename(integer(), list(map())) :: {:ok, map()} | {:error, String.t()}
  defp execute_movie_rename(movie_id, renameable_files) do
    # Extract movie file IDs from the renameable files response and ensure they're integers
    file_ids =
      renameable_files
      |> Enum.map(fn file -> file["movieFileId"] end)

    # Parse all file IDs, collecting successes and failures
    {successes, failures} =
      file_ids
      |> Enum.map(&parse_file_id/1)
      |> Enum.split_with(fn
        {:ok, _} -> true
        {:error, _} -> false
      end)

    # If any parsing failed, return early with error
    if Enum.empty?(failures) do
      # Extract successful IDs
      renameable_file_ids = Enum.map(successes, fn {:ok, id} -> id end)

      json_payload = %{
        name: "RenameFiles",
        files: renameable_file_ids
      }

      Logger.info(
        "Radarr rename_movie_files request - Movie ID: #{movie_id}, File IDs: #{inspect(renameable_file_ids)}"
      )

      Logger.debug("Radarr rename_movie_files JSON payload: #{inspect(json_payload)}")

      case request(
             url: "/api/v3/command",
             method: :post,
             json: json_payload
           ) do
        {:ok, response} = result ->
          Logger.debug("Radarr rename_movie_files response: #{inspect(response.body)}")
          result

        {:error, reason} = error ->
          Logger.error("Radarr rename_movie_files error: #{inspect(reason)}")
          error
      end
    else
      error_msgs = Enum.map(failures, fn {:error, msg} -> msg end)
      {:error, "Failed to parse movie file IDs: #{Enum.join(error_msgs, ", ")}"}
    end
  end

  # Helper function to parse file IDs from various formats to integers
  @spec parse_file_id(any()) :: {:ok, integer()} | {:error, String.t()}
  defp parse_file_id(value) when is_integer(value), do: {:ok, value}

  defp parse_file_id(value) when is_binary(value) do
    case Parsers.parse_integer_exact(value) do
      {:ok, int} -> {:ok, int}
      {:error, _} -> {:error, "invalid integer format"}
    end
  end

  defp parse_file_id(value) do
    {:error, "expected integer or string, got: #{inspect(value)}"}
  end
end
