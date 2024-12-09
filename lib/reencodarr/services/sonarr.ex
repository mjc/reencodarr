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

  @spec get_shows() :: {:error, any()} | {:ok, any()}
  def get_shows do
    request(url: "/api/v3/series?includeSeasonImages=false", method: :get)
  end

  def get_episodes(series_id) do
    request(url: "/api/v3/episode?seriesId=#{series_id}", method: :get)
  end

  def get_episode_files(series_id) do
    request(url: "/api/v3/episodefile?seriesId=#{series_id}", method: :get)
  end
end
