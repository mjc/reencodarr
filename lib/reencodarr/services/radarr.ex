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

  @doc """
  Refresh a movie and wait for the command to complete.
  Returns {:ok, response} when complete, {:error, reason} on failure or timeout.
  """
  @spec refresh_movie_and_wait(integer(), keyword()) :: {:ok, map()} | {:error, any()}
  def refresh_movie_and_wait(movie_id, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, 60)
    poll_interval = Keyword.get(opts, :poll_interval, 1000)

    case refresh_movie(movie_id) do
      {:ok, %{body: %{"id" => command_id}}} ->
        Logger.info("Waiting for RefreshMovie command #{command_id} to complete...")
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

  @spec rename_movie_files(integer() | nil) ::
          {:ok, Req.Response.t()} | {:error, any()}
  def rename_movie_files(movie_id)

  def rename_movie_files(nil) do
    ErrorHelpers.handle_nil_value(nil, "Movie ID", "Cannot rename files")
  end

  def rename_movie_files(movie_id) when is_integer(movie_id) do
    # Retry up to 3 times if no renameable files found
    case retry_get_radarr_renameable_files(movie_id, 3) do
      [] ->
        Logger.warning("No files need renaming for movie ID: #{movie_id} after retries")
        {:ok, %{message: "No files need renaming"}}

      renameable_files ->
        execute_movie_rename(movie_id, renameable_files)
    end
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

  # Retry getting renameable files with exponential backoff.
  # Implements exponential backoff with the formula: base_delay * 2^(attempt-1)
  # This results in delays of: 1s, 2s, 4s, 8s, etc.
  # This allows Radarr time to index the renamed file while minimizing polling overhead.
  defp retry_get_radarr_renameable_files(movie_id, retries_left, attempt \\ 1)

  defp retry_get_radarr_renameable_files(movie_id, retries_left, attempt)
       when retries_left > 0 do
    files = get_radarr_renameable_files(movie_id)

    if Enum.empty?(files) do
      Logger.debug("No renameable files yet for movie #{movie_id}, retries left: #{retries_left}")

      # Exponential backoff: base_delay * 2^(attempt-1)
      # Attempt 1: 1s, Attempt 2: 2s, Attempt 3: 4s, etc.
      base_delay_ms = 1000
      delay_ms = round(:math.pow(2, attempt - 1) * base_delay_ms)
      Process.sleep(delay_ms)
      retry_get_radarr_renameable_files(movie_id, retries_left - 1, attempt + 1)
    else
      files
    end
  end

  defp retry_get_radarr_renameable_files(_movie_id, 0, _attempt), do: []

  @spec execute_movie_rename(integer(), list(map())) ::
          {:ok, map()} | {:error, String.t()}
  defp execute_movie_rename(movie_id, renameable_files) do
    with {:ok, file_ids} <- parse_renameable_file_ids(renameable_files) do
      execute_rename_api_request(movie_id, file_ids)
    end
  end

  @spec parse_renameable_file_ids(list(map())) :: {:ok, list(integer())} | {:error, String.t()}
  defp parse_renameable_file_ids(renameable_files) do
    renameable_files
    |> Enum.map(& &1["movieFileId"])
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
  defp execute_rename_api_request(movie_id, files_to_rename) do
    json_payload = %{
      name: "RenameFiles",
      movieId: movie_id,
      files: files_to_rename
    }

    Logger.info(
      "Radarr rename_movie_files request - Movie ID: #{movie_id}, File IDs: #{inspect(files_to_rename)}"
    )

    Logger.debug("Radarr rename_movie_files JSON payload: #{inspect(json_payload)}")

    case request(
           url: "/api/v3/command",
           method: :post,
           json: json_payload
         ) do
      {:ok, %{body: %{"id" => command_id}} = response} ->
        Logger.debug("Radarr rename_movie_files response: #{inspect(response.body)}")
        # Wait for the rename command to complete
        Logger.info("Waiting for RenameFiles command #{command_id} to complete...")
        wait_for_command(command_id)

      {:ok, response} ->
        Logger.warning(
          "Radarr rename_movie_files response missing command ID: #{inspect(response.body)}"
        )

        {:ok, response}

      {:error, reason} = error ->
        Logger.error("Radarr rename_movie_files error: #{inspect(reason)}")
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
