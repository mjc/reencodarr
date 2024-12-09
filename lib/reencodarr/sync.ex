defmodule Reencodarr.Sync do
  @moduledoc """
  This module is responsible for syncing data between services and Reencodarr.
  """
  alias Reencodarr.{Media, Services}
  alias Ecto.Multi
  alias Reencodarr.Repo
  require Logger

  def sync_episode_files do
    case Services.Sonarr.get_shows() do
      {:ok, %Req.Response{body: shows}} ->
        shows
        |> Enum.map(& &1["id"])
        |> Enum.map(&fetch_and_upsert_episode_files/1)
        |> List.flatten()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_and_upsert_episode_files(series_id) do
    case Services.Sonarr.get_episode_files(series_id) do
      {:ok, %Req.Response{body: files}} ->
        multi =
          Enum.reduce(files, Multi.new(), fn file, multi ->
            attrs = %{
              path: file["path"],
              size: file["size"],
              service_id: to_string(file["id"]),
              service_type: "sonarr"
            }

            Multi.run(multi, "upsert_video_#{file["id"]}", fn _repo, _changes ->
              Media.upsert_video(attrs)
            end)
          end)

        case Repo.transaction(multi) do
          {:ok, results} ->
            Enum.map(results, fn {_, video} -> video end)

          {:error, _failed_operation, failed_value, _changes} ->
            Logger.error("Failed to upsert video: #{inspect(failed_value)}")
            []
        end

      {:error, _} ->
        []
    end
  end

  def upsert_video_from_episode_file(episode_file) do
    attrs = %{
      path: episode_file["path"],
      size: episode_file["size"],
      service_id: to_string(episode_file["id"]),
      service_type: :sonarr
    }

    case Media.upsert_video(attrs) do
      {:ok, video} ->
        video

      {:error, changeset} ->
        Logger.error("Failed to upsert video: #{inspect(changeset)}")
        changeset
    end
  end

  def refresh_and_rename_from_video(%{service_type: :sonarr, service_id: episode_file_id} = video) do
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
