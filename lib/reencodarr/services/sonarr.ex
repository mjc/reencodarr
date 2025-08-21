defmodule Reencodarr.Services.Sonarr do
  @moduledoc """
  This module is responsible for communicating with the Sonarr API.
  """
  require Logger
  alias Reencodarr.ErrorHelpers
  alias Reencodarr.Services

  use CarReq,
    pool_timeout: 100,
    receive_timeout: 9_000,
    retry: :safe_transient,
    max_retries: 3,
    fuse_opts: {{:standard, 5, 30_000}, {:reset, 60_000}}

  def client_options do
    case Services.get_sonarr_config() do
      {:ok, %{url: url, api_key: api_key}} ->
        [base_url: url, headers: ["X-Api-Key": api_key]]

      {:error, :not_found} ->
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
      perform_series_refresh(series_id)
      Process.sleep(2000)

      case get_renameable_files(series_id) do
        [] ->
          Logger.info("No files need renaming for series ID: #{series_id}")
          {:ok, %{message: "No files need renaming"}}

        renameable_files ->
          execute_rename_request(series_id, file_ids, renameable_files)
      end
    end
  end

  @spec refresh_and_rename_all_series :: :ok
  def refresh_and_rename_all_series do
    get_shows()
    |> case do
      {:ok, %Req.Response{body: shows}} ->
        shows
        |> Enum.take(10)
        |> Task.async_stream(
          fn %{"id" => series_id} ->
            # Pass empty list to rename all renameable files for this series
            rename_files(series_id, [])
          end,
          max_concurrency: 1
        )
        |> Stream.run()

      {:error, err} ->
        Logger.error("Failed to get shows: #{inspect(err)}")
    end
  end

  # Performs series refresh and logs results
  defp perform_series_refresh(series_id) do
    Logger.info("Refreshing series ID: #{series_id} before checking for renameable files")

    ErrorHelpers.handle_error_with_warning(
      refresh_series(series_id),
      :ok,
      "Failed to refresh series"
    )
  end

  # Fetch renameable files with logging
  defp get_renameable_files(series_id) do
    Logger.info("Checking renameable files for series ID: #{series_id}")

    request(url: "/api/v3/rename?seriesId=#{series_id}", method: :get)
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

  # Execute rename command and return result
  defp execute_rename_request(series_id, file_ids, renameable_files) do
    renameable_file_ids = Enum.map(renameable_files, & &1["episodeFileId"])
    files_to_rename = if file_ids == [], do: renameable_file_ids, else: file_ids
    json_payload = %{name: "RenameFiles", seriesId: series_id, files: files_to_rename}

    Logger.info(
      "Sonarr rename_files request - Series ID: #{series_id}, File IDs: #{inspect(files_to_rename)}"
    )

    Logger.debug("Sonarr rename_files JSON payload: #{inspect(json_payload)}")

    case request(
           url: "/api/v3/command",
           method: :post,
           json: json_payload
         ) do
      {:ok, response} = result ->
        Logger.debug("Sonarr rename_files response: #{inspect(response.body)}")
        result

      {:error, reason} = error ->
        Logger.error("Sonarr rename_files error: #{inspect(reason)}")
        error
    end
  end
end
