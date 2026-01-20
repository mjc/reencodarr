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

  @doc """
  Refresh a series and wait for the command to complete.
  Returns {:ok, response} when complete, {:error, reason} on failure or timeout.
  """
  @spec refresh_series_and_wait(integer(), keyword()) :: {:ok, map()} | {:error, any()}
  def refresh_series_and_wait(series_id, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, 60)
    poll_interval = Keyword.get(opts, :poll_interval, 1000)

    case refresh_series(series_id) do
      {:ok, %{body: %{"id" => command_id}}} ->
        Logger.info("Waiting for RefreshSeries command #{command_id} to complete...")
        wait_for_command(command_id, max_attempts, poll_interval)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get the status of a command by ID.
  """
  @spec get_command_status(integer()) :: {:ok, map()} | {:error, any()}
  def get_command_status(command_id) do
    case request(url: "/api/v3/command/#{command_id}", method: :get) do
      {:ok, %{body: body}} -> {:ok, body}
      error -> error
    end
  end

  @doc """
  Wait for a command to complete, polling until done or timeout.
  """
  @spec wait_for_command(integer(), integer(), integer()) :: {:ok, map()} | {:error, any()}
  def wait_for_command(command_id, max_attempts \\ 60, poll_interval \\ 1000) do
    do_wait_for_command(command_id, max_attempts, poll_interval, 0)
  end

  defp do_wait_for_command(_command_id, max_attempts, _poll_interval, attempts)
       when attempts >= max_attempts do
    Logger.warning("Timeout waiting for command to complete after #{max_attempts} attempts")
    {:error, :timeout}
  end

  defp do_wait_for_command(command_id, max_attempts, poll_interval, attempts) do
    case get_command_status(command_id) do
      {:ok, %{"status" => "completed"} = response} ->
        Logger.info("Command #{command_id} completed successfully")
        {:ok, response}

      {:ok, %{"status" => "failed", "message" => message}} ->
        Logger.error("Command #{command_id} failed: #{message}")
        {:error, {:command_failed, message}}

      {:ok, %{"status" => status}} ->
        Logger.debug(
          "Command #{command_id} status: #{status} (attempt #{attempts + 1}/#{max_attempts})"
        )

        Process.sleep(poll_interval)
        do_wait_for_command(command_id, max_attempts, poll_interval, attempts + 1)

      {:error, reason} ->
        Logger.error("Failed to get command status: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec rename_files(integer(), [integer()]) :: {:ok, Req.Response.t()} | {:error, any()}
  def rename_files(series_id, _file_ids) when not is_integer(series_id) do
    Logger.error("Series ID must be an integer, got: #{inspect(series_id)}")
    {:error, :invalid_series_id}
  end

  def rename_files(series_id, _file_ids) when series_id <= 0 do
    Logger.error("Series ID must be positive, got: #{series_id}")
    {:error, :invalid_series_id}
  end

  def rename_files(series_id, _file_ids) when is_integer(series_id) do
    # Retry up to 3 times if no renameable files found
    case retry_get_renameable_files(series_id, 3) do
      [] ->
        Logger.warning("No files need renaming for series ID: #{series_id} after retries")
        {:ok, %{message: "No files need renaming"}}

      renameable_files ->
        execute_rename_request(series_id, renameable_files)
    end
  end

  @spec refresh_and_rename_all_series :: :ok
  def refresh_and_rename_all_series do
    case get_shows() do
      {:ok, %Req.Response{body: shows}} ->
        shows
        |> Enum.take(10)
        |> Task.async_stream(&refresh_and_rename_series/1, max_concurrency: 1)
        |> Stream.run()

      {:error, err} ->
        Logger.error("Failed to get shows: #{inspect(err)}")
    end
  end

  defp refresh_and_rename_series(%{"id" => series_id}) do
    case refresh_series_and_wait(series_id) do
      {:ok, _} ->
        rename_files(series_id, [])

      {:error, reason} ->
        Logger.error("Failed to refresh series #{series_id}: #{inspect(reason)}")
    end
  end

  # Retry getting renameable files with exponential backoff
  defp retry_get_renameable_files(series_id, retries_left, attempt \\ 1)

  defp retry_get_renameable_files(series_id, retries_left, attempt)
       when retries_left > 0 do
    files = get_renameable_files(series_id)

    if Enum.empty?(files) do
      Logger.debug(
        "No renameable files yet for series #{series_id}, retries left: #{retries_left}"
      )

      # Exponential backoff: 1s, 2s, 4s, etc.
      base_delay_ms = 1000
      delay_ms = round(:math.pow(2, attempt - 1) * base_delay_ms)
      Process.sleep(delay_ms)
      retry_get_renameable_files(series_id, retries_left - 1, attempt + 1)
    else
      files
    end
  end

  defp retry_get_renameable_files(_series_id, 0, _attempt), do: []

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
  @spec execute_rename_request(integer(), list(map())) ::
          {:ok, map()} | {:error, String.t()}
  defp execute_rename_request(series_id, renameable_files) do
    with {:ok, file_ids} <- parse_renameable_file_ids(renameable_files) do
      execute_rename_api_request(series_id, file_ids)
    end
  end

  @spec parse_renameable_file_ids(list(map())) :: {:ok, list(integer())} | {:error, String.t()}
  defp parse_renameable_file_ids(renameable_files) do
    renameable_files
    |> Enum.map(& &1["episodeFileId"])
    |> Enum.map(&parse_file_id/1)
    |> collect_results()
  end

  defp collect_results(results) do
    case Enum.split_with(results, &match?({:ok, _}, &1)) do
      {successes, []} ->
        {:ok, Enum.map(successes, fn {:ok, id} -> id end)}

      {_successes, failures} ->
        error_msgs = Enum.map(failures, fn {:error, msg} -> msg end)
        {:error, "Failed to parse renameable file IDs: #{Enum.join(error_msgs, ", ")}"}
    end
  end

  @spec execute_rename_api_request(integer(), list(integer())) ::
          {:ok, map()} | {:error, String.t()}
  defp execute_rename_api_request(series_id, files_to_rename) do
    json_payload = %{
      name: "RenameFiles",
      seriesId: series_id,
      files: files_to_rename
    }

    Logger.info(
      "Sonarr rename_files request - Series ID: #{series_id}, File IDs: #{inspect(files_to_rename)}"
    )

    Logger.debug("Sonarr rename_files JSON payload: #{inspect(json_payload)}")

    case request(
           url: "/api/v3/command",
           method: :post,
           json: json_payload
         ) do
      {:ok, %{body: %{"id" => command_id}} = response} ->
        Logger.debug("Sonarr rename_files response: #{inspect(response.body)}")
        # Wait for the rename command to complete
        Logger.info("Waiting for RenameFiles command #{command_id} to complete...")
        wait_for_command(command_id)

      {:ok, response} ->
        Logger.warning(
          "Sonarr rename_files response missing command ID: #{inspect(response.body)}"
        )

        {:ok, response}

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
end
