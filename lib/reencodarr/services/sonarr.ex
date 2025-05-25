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
      json: %{name: "RefreshSeries", seriesId: series_id}
    )
  end

  @spec rename_files(integer()) :: {:ok, Req.Response.t()} | {:error, any()}
  def rename_files(series_id) do
    request(
      url: "/api/v3/rename",
      method: :post,
      query: %{seriesId: series_id}
    )
  end

  @spec refresh_and_rename_all_series() :: :ok
  def refresh_and_rename_all_series() do
    get_shows()
    |> case do
      {:ok, %Req.Response{body: shows}} ->
        shows
        |> Enum.take(10)
        |> Task.async_stream(
          fn %{"id" => id} ->
            # refresh_series(id)
            rename_files(id)
          end,
          max_concurrency: 1
        )
        |> Stream.run()

      {:error, err} ->
        Logger.error("Failed to get shows: #{inspect(err)}")
    end
  end
end
