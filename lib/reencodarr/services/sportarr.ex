defmodule Reencodarr.Services.Sportarr do
  @moduledoc "Client for Sportarr's Sonarr-compatible catalog API."
  require Logger
  alias Reencodarr.Services

  use CarReq,
    pool_timeout: 100,
    receive_timeout: 9_000,
    retry: :safe_transient,
    max_retries: 3,
    fuse_opts: {{:standard, 5, 30_000}, {:reset, 60_000}}

  def client_options do
    case Services.get_sportarr_config() do
      {:ok, %{url: url, api_key: api_key}} ->
        [base_url: url, headers: ["X-Api-Key": api_key]]

      {:error, :not_found} ->
        Logger.error("Sportarr config not found")
        []
    end
  end

  @doc "Returns Sportarr leagues using the Sonarr-compatible series endpoint."
  def get_shows do
    request(url: "/api/v3/series?includeSeasonImages=false", method: :get)
  end

  @doc "Returns episode files for a Sportarr league."
  def get_episode_files(league_id) do
    request(url: "/api/v3/episodefile?seriesId=#{league_id}", method: :get)
  end

  def get_episode_file(file_id), do: request(url: "/api/v3/episodefile/#{file_id}", method: :get)

  def get_episodes_by_file(file_id),
    do: request(url: "/api/v3/episode?episodeFileId=#{file_id}", method: :get)

  def refresh_series(league_id) do
    request(
      url: "/api/v3/command",
      method: :post,
      json: %{name: "RefreshSeries", commandName: "RefreshSeries", seriesId: league_id}
    )
  end

  def set_episodes_monitored(episode_ids, monitored) do
    request(
      url: "/api/v3/episode/monitor",
      method: :put,
      json: %{episodeIds: episode_ids, monitored: monitored}
    )
  end

  def delete_episode_file(file_id),
    do: request(url: "/api/v3/episodefile/#{file_id}", method: :delete)

  def trigger_episode_search(episode_ids) do
    request(
      url: "/api/v3/command",
      method: :post,
      json: %{name: "EpisodeSearch", episodeIds: episode_ids}
    )
  end
end
