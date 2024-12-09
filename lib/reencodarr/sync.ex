defmodule Reencodarr.Sync do
  @moduledoc """
  This module is responsible for syncing data between services and Reencodarr.
  """
  alias Reencodarr.{Media, Services}
  require Logger

  def sync_episode_files do
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
      {:ok, %Req.Response{body: files}} ->
        Enum.map(files, &upsert_video_from_episode_file/1)

      {:error, _} ->
        []
    end
  end

  def upsert_video_from_episode_file(episode_file) do
    attrs = %{
      path: episode_file["path"],
      size: episode_file["size"],
      service_id: to_string(episode_file["id"]),
      service_type: "sonarr"
    }

    case Media.upsert_video(attrs) do
      {:ok, video} ->
        video

      {:error, changeset} ->
        Logger.error("Failed to upsert video: #{inspect(changeset)}")
        changeset
    end
  end

  def refresh_and_rename_from_video(%{service_type: :sonarr} = video) do
    episode_file_id = video.service_id

    with {:ok, %Req.Response{body: episode_file}} <-
           Services.Sonarr.get_episode_file(episode_file_id),
         {:ok, _refresh_series} <- Services.Sonarr.refresh_series(episode_file["seriesId"]),
         {:ok, _rename_files} <- Services.Sonarr.rename_files(episode_file["seriesId"]) do
      {:ok, "Refresh and rename triggered successfully"}
    else
      {:error, reason} -> {:error, reason}
    end
  end
end
