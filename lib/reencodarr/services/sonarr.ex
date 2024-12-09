defmodule Reencodarr.Services.Sonarr do
  @moduledoc """
  This module is responsible for communicating with the Sonarr API.
  """
  require Logger
  alias Reencodarr.Services

  use CarReq,
    pool_timeout: 100,
    receive_timeout: 999,
    retry: :safe_transient,
    max_retries: 3,
    fuse_opts: {{:standard, 5, 10_000}, {:reset, 30_000}}

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
    case request(url: "/api/v3/system/status", method: :get) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, "Unexpected status code: #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
