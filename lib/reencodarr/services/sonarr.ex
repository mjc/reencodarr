defmodule Reencodarr.Services.Sonarr do
  @moduledoc """
  This module is responsible for communicating with the Sonarr API.
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
    cond do
      not is_integer(series_id) ->
        Logger.error("Series ID must be an integer, got: #{inspect(series_id)}")
        {:error, :invalid_series_id}

      series_id <= 0 ->
        Logger.error("Series ID must be positive, got: #{series_id}")
        {:error, :invalid_series_id}

      true ->
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
  @spec execute_rename_request(integer(), list(), list(map())) ::
          {:ok, map()} | {:error, String.t()}
  defp execute_rename_request(series_id, file_ids, renameable_files) do
    with {:ok, renameable_file_ids} <- parse_renameable_files(renameable_files),
         {:ok, files_to_rename} <- determine_files_to_rename(file_ids, renameable_file_ids) do
      execute_rename_api_request(series_id, files_to_rename)
    end
  end

  @spec parse_renameable_files(list(map())) :: {:ok, list(integer())} | {:error, String.t()}
  defp parse_renameable_files(renameable_files) do
    # Parse renameable file IDs from API response
    parsed_renameable =
      renameable_files
      |> Enum.map(& &1["episodeFileId"])
      |> Enum.map(&parse_file_id/1)

    # Check for parsing errors in renameable files
    {renameable_successes, renameable_failures} =
      Enum.split_with(parsed_renameable, fn
        {:ok, _} -> true
        {:error, _} -> false
      end)

    if Enum.empty?(renameable_failures) do
      renameable_file_ids = Enum.map(renameable_successes, fn {:ok, id} -> id end)
      {:ok, renameable_file_ids}
    else
      error_msgs = Enum.map(renameable_failures, fn {:error, msg} -> msg end)
      {:error, "Failed to parse renameable file IDs: #{Enum.join(error_msgs, ", ")}"}
    end
  end

  @spec determine_files_to_rename(list(), list(integer())) ::
          {:ok, list(integer())} | {:error, String.t()}
  defp determine_files_to_rename(file_ids, renameable_file_ids) do
    if file_ids == [] do
      {:ok, renameable_file_ids}
    else
      parse_explicit_file_ids(file_ids)
    end
  end

  @spec execute_rename_api_request(integer(), list(integer())) ::
          {:ok, map()} | {:error, String.t()}
  defp execute_rename_api_request(series_id, files_to_rename) do
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

  @spec parse_explicit_file_ids(list()) :: {:ok, list(integer())} | {:error, String.t()}
  defp parse_explicit_file_ids(file_ids) do
    parsed_explicit = file_ids |> Enum.map(&parse_file_id/1)

    {explicit_successes, explicit_failures} =
      Enum.split_with(parsed_explicit, fn
        {:ok, _} -> true
        {:error, _} -> false
      end)

    if Enum.empty?(explicit_failures) do
      parsed_ids = Enum.map(explicit_successes, fn {:ok, id} -> id end)
      {:ok, parsed_ids}
    else
      error_msgs = Enum.map(explicit_failures, fn {:error, msg} -> msg end)
      {:error, "Failed to parse explicit file IDs: #{Enum.join(error_msgs, ", ")}"}
    end
  end
end
