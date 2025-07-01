defmodule Reencodarr.Services.Radarr do
  @moduledoc """
  This module is responsible for communicating with the Radarr API.
  """
  require Logger
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
        Logger.error("Radarr config not found")
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
    Logger.error("Movie ID is null, cannot rename files")
    {:error, :invalid_movie_id}
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

    case refresh_movie(movie_id) do
      {:ok, refresh_response} ->
        Logger.info("Movie refresh initiated: #{inspect(refresh_response.body)}")

      {:error, reason} ->
        Logger.warning("Failed to refresh movie (continuing anyway): #{inspect(reason)}")
    end
  end

  defp get_radarr_renameable_files(movie_id) do
    Logger.info("Checking renameable files for movie ID: #{movie_id}")

    case request(url: "/api/v3/rename?movieId=#{movie_id}", method: :get) do
      {:ok, rename_response} ->
        Logger.info("Renameable files response: #{inspect(rename_response.body)}")
        rename_response.body

      {:error, reason} ->
        Logger.error("Failed to get renameable files: #{inspect(reason)}")
        []
    end
  end

  defp execute_movie_rename(movie_id, renameable_files) do
    # Extract movie file IDs from the renameable files response
    renameable_file_ids = Enum.map(renameable_files, fn file -> file["movieFileId"] end)

    json_payload = %{
      name: "RenameFiles",
      files: renameable_file_ids
    }

    Logger.info(
      "Radarr rename_movie_files request - Movie ID: #{movie_id}, File IDs: #{inspect(renameable_file_ids)}"
    )

    Logger.info("Radarr rename_movie_files JSON payload: #{inspect(json_payload)}")

    case request(
           url: "/api/v3/command",
           method: :post,
           json: json_payload
         ) do
      {:ok, response} = result ->
        Logger.info("Radarr rename_movie_files response: #{inspect(response.body)}")
        result

      {:error, reason} = error ->
        Logger.error("Radarr rename_movie_files error: #{inspect(reason)}")
        error
    end
  end
end
