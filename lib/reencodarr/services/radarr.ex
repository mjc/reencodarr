defmodule Reencodarr.Services.Radarr do
  @moduledoc """
  This module is responsible for communicating with the Radarr API.
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
      %{url: url, api_key: api_key} = Services.get_radarr_config!()
      [base_url: url, headers: ["X-Api-Key": api_key]]
    rescue
      Ecto.NoResultsError ->
        Logger.error("Radarr config not found")
        []
    end
  end

  def system_status do
    request(url: "/api/v3/system/status", method: :get)
  end

  @spec get_movies() :: {:ok, any()} | {:error, any()}
  def get_movies do
    request(url: "/api/v3/movie", method: :get)
  end

  def get_movie_files(movie_id) do
    request(url: "/api/v3/moviefile?movieId=#{movie_id}", method: :get)
  end
end
