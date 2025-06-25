defmodule Reencodarr.Services.Sonarr do
  @moduledoc """
  This module is responsible for communicating with the Sonarr API.
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
    try do
      %{url: url, api_key: api_key} = Services.get_sonarr_config!()
      [base_url: url, headers: ["X-Api-Key": api_key]]
    rescue
      Ecto.NoResultsError ->
        Logger.error("Sonarr config not found")
        []
    end
  end

  def system_status do
    request(url: "/api/v3/system/status", method: :get)
  end

  @spec get_shows() :: {:ok, Req.Response.t()} | {:error, any()}
  def get_shows do
    request(url: "/api/v3/series?includeSeasonImages=false", method: :get)
  end

  @spec get_episode_files(integer()) :: {:ok, Req.Response.t()} | {:error, any()}
  def get_episode_files(series_id) do
    response = request(url: "/api/v3/episodefile?seriesId=#{series_id}", method: :get)
    response
  end

  @spec get_episode_file(integer()) :: {:ok, Req.Response.t()} | {:error, any()}
  def get_episode_file(episode_file_id) do
    request(url: "/api/v3/episodefile/#{episode_file_id}", method: :get)
  end

  @spec refresh_series(integer()) :: {:ok, Req.Response.t()} | {:error, any()}
  def refresh_series(series_id) do
    request(
      url: "/api/v3/command",
      method: :post,
      json: %{name: "RefreshSeries", commandName: "RefreshSeries", seriesId: series_id}
    )
  end

  @spec rename_files(integer(), [integer()]) :: {:ok, Req.Response.t()} | {:error, any()}
  def rename_files(series_id, file_ids) when is_list(file_ids) do
    if series_id == nil do
      Logger.error("Series ID is null, cannot rename files")
      {:error, :invalid_series_id}
    else
      # First refresh the series to update media info
      Logger.info("Refreshing series ID: #{series_id} before checking for renameable files")

      case refresh_series(series_id) do
        {:ok, refresh_response} ->
          Logger.info("Series refresh initiated: #{inspect(refresh_response.body)}")

        {:error, reason} ->
          Logger.warning("Failed to refresh series (continuing anyway): #{inspect(reason)}")
      end

      # Give Sonarr a moment to process the refresh
      Process.sleep(2000)

      # Check what files can be renamed after refresh
      Logger.info("Checking renameable files for series ID: #{series_id}")

      renameable_files =
        case request(url: "/api/v3/rename?seriesId=#{series_id}", method: :get) do
          {:ok, rename_response} ->
            Logger.info("Renameable files response: #{inspect(rename_response.body)}")
            rename_response.body

          {:error, reason} ->
            Logger.error("Failed to get renameable files: #{inspect(reason)}")
            []
        end

      # If no files need renaming, don't send the command
      if Enum.empty?(renameable_files) do
        Logger.info("No files need renaming for series ID: #{series_id}")
        {:ok, %{message: "No files need renaming"}}
      else
        # Extract episode file IDs from the renameable files response
        renameable_file_ids = Enum.map(renameable_files, fn file -> file["episodeFileId"] end)

        # Use the file IDs from the renameable files response, or fall back to provided IDs
        files_to_rename = if Enum.empty?(file_ids), do: renameable_file_ids, else: file_ids

        json_payload = %{
          name: "RenameFiles",
          seriesId: series_id,
          files: files_to_rename
        }

        Logger.info(
          "Sonarr rename_files request - Series ID: #{series_id}, File IDs: #{inspect(files_to_rename)}"
        )

        Logger.info("Sonarr rename_files JSON payload: #{inspect(json_payload)}")

        case request(
               url: "/api/v3/command",
               method: :post,
               json: json_payload
             ) do
          {:ok, response} = result ->
            Logger.info("Sonarr rename_files response: #{inspect(response.body)}")
            result

          {:error, reason} = error ->
            Logger.error("Sonarr rename_files error: #{inspect(reason)}")
            error
        end
      end
    end
  end

  @spec refresh_and_rename_all_series() :: :ok
  def refresh_and_rename_all_series() do
    get_shows()
    |> case do
      {:ok, %Req.Response{body: shows}} ->
        shows
        |> Enum.take(10)
        |> Task.async_stream(
          fn %{"id" => series_id} ->
            # TODO: fix this
            rename_files(series_id, [])
          end,
          max_concurrency: 1
        )
        |> Stream.run()

      {:error, err} ->
        Logger.error("Failed to get shows: #{inspect(err)}")
    end
  end
end
