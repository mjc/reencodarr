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
    case Services.get_sonarr_config!() do
      {:ok, %{url: url, api_key: api_key}} ->
        [base_url: url, headers: ["X-Api-Key": api_key]]

      {:error, reason} ->
        Logger.error("Failed to get Sonarr config: #{reason}")
        []
    end
  end
end
