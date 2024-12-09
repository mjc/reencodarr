defmodule Reencodarr.Sync do
  @moduledoc """
  This module is responsible for syncing data between services and Reencodarr.
  """
  alias Reencodarr.Services

  def get_all_episode_files do
    case Services.Sonarr.get_shows() do
      {:ok, %Req.Response{body: shows}} ->
        shows
        |> Enum.map(& &1["id"])
        |> Enum.flat_map(&fetch_episode_files/1)
        |> List.flatten()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_episode_files(series_id) do
    case Services.Sonarr.get_episode_files(series_id) do
      {:ok, %Req.Response{body: files}} -> files |> dbg
      {:error, _} -> []
    end
  end
end
