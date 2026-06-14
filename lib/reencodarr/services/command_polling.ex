defmodule Reencodarr.Services.CommandPolling do
  @moduledoc "Shared command status polling for Sonarr and Radarr clients."

  require Logger

  @type request_fun :: (keyword() -> {:ok, Req.Response.t()} | {:error, any()})

  @spec get_status(integer(), request_fun()) :: {:ok, map()} | {:error, any()}
  def get_status(command_id, request_fun) do
    case request_fun.(url: "/api/v3/command/#{command_id}", method: :get) do
      {:ok, %{body: body}} -> {:ok, body}
      error -> error
    end
  end

  @spec wait(integer(), integer(), integer(), request_fun()) :: {:ok, map()} | {:error, any()}
  def wait(command_id, max_attempts, poll_interval, request_fun) do
    do_wait(command_id, max_attempts, poll_interval, 0, request_fun)
  end

  defp do_wait(_command_id, max_attempts, _poll_interval, attempts, _request_fun)
       when attempts >= max_attempts do
    Logger.warning("Timeout waiting for command to complete after #{max_attempts} attempts")
    {:error, :timeout}
  end

  defp do_wait(command_id, max_attempts, poll_interval, attempts, request_fun) do
    case get_status(command_id, request_fun) do
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
        do_wait(command_id, max_attempts, poll_interval, attempts + 1, request_fun)

      {:error, reason} ->
        Logger.error("Failed to get command status: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
