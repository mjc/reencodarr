defmodule ReencodarrWeb.SonarrWebhookController do
  use ReencodarrWeb, :controller
  require Logger

  def sonarr(conn, %{"eventType" => "Test"} = params), do: handle_test(conn, params)
  def sonarr(conn, %{"eventType" => "Grab"} = params), do: handle_grab(conn, params)
  def sonarr(conn, %{"eventType" => "Download"} = params), do: handle_download(conn, params)

  def sonarr(conn, %{"eventType" => "EpisodeFileDelete"} = params),
    do: handle_delete(conn, params)

  def sonarr(conn, %{"eventType" => "Rename"} = params), do: handle_rename(conn, params)
  def sonarr(conn, %{"eventType" => "EpisodeFile"} = params), do: handle_episodefile(conn, params)
  def sonarr(conn, %{"eventType" => "SeriesAdd"} = params), do: handle_series_add(conn, params)

  def sonarr(conn, %{"eventType" => "SeriesDelete"} = params),
    do: handle_series_delete(conn, params)

  def sonarr(conn, params), do: handle_unknown(conn, params)

  defp handle_test(conn, _params) do
    Logger.info("Received test event from Sonarr!")
    send_resp(conn, :no_content, "")
  end

  defp handle_grab(conn, %{"release" => %{"releaseTitle" => title}}) do
    Logger.debug("Received grab event from Sonarr for #{title}!")
    send_resp(conn, :no_content, "")
  end

  defp handle_download(conn, %{"episodeFiles" => episode_files} = _params)
       when is_list(episode_files) do
    results =
      Enum.map(episode_files, fn file ->
        scene_name = file["sceneName"] || Path.basename(file["path"])
        Logger.info("Received download event from Sonarr for #{scene_name}!")
        Reencodarr.Sync.upsert_video_from_file(file, :sonarr)
      end)

    if Enum.all?(results, fn res -> res == :ok or match?({:ok, _}, res) end) do
      Logger.info("Successfully processed download event for Sonarr")
    else
      Logger.error("Some upserts failed for download event: #{inspect(results)}")
    end

    send_resp(conn, :no_content, "")
  end

  defp handle_download(conn, %{"episodeFile" => episode_file} = _params)
       when is_map(episode_file) do
    scene_name = episode_file["sceneName"] || Path.basename(episode_file["path"])
    Logger.info("Received download event from Sonarr for #{scene_name}!")
    Reencodarr.Sync.upsert_video_from_file(episode_file, :sonarr)
    send_resp(conn, :no_content, "")
  end

  defp handle_delete(conn, %{"episodeFile" => episode_file}) do
    Logger.info("Received delete event from Sonarr for episode file: #{inspect(episode_file)}")
    path = episode_file["path"]

    case Reencodarr.Sync.delete_video_and_vmafs(path) do
      :ok ->
        Logger.info("Deleted video and vmafs for path: #{path}")

      {:error, reason} ->
        Logger.error("Failed to delete video and vmafs for path #{path}: #{inspect(reason)}")
    end

    send_resp(conn, :no_content, "")
  end

  defp handle_rename(conn, %{"renamedEpisodeFiles" => renamed_files}) do
    Logger.debug("Received rename event from Sonarr for files: #{inspect(renamed_files)}")

    Enum.each(renamed_files, &update_or_upsert_video(&1, :sonarr))

    send_resp(conn, :no_content, "")
  end

  defp update_or_upsert_video(%{"previousPath" => old_path, "path" => new_path} = file, source) do
    case Reencodarr.Media.get_video_by_path(old_path) do
      nil ->
        Logger.warning("No video found for old path: #{old_path}, upserting as new")
        Reencodarr.Sync.upsert_video_from_file(file, source)

      video ->
        video
        |> Reencodarr.Media.update_video(%{path: new_path})
        |> handle_update_result(video, old_path, new_path, file, source)
    end
  end

  defp handle_update_result({:ok, _}, _video, old_path, new_path, _file, _source) do
    Logger.info("Updated video path from #{old_path} to #{new_path}")
  end

  defp handle_update_result(
         {:error, %Ecto.Changeset{errors: [path: {"has already been taken", _}]}},
         video,
         old_path,
         new_path,
         file,
         source
       ) do
    Logger.warning(
      "Video with path #{new_path} already exists, removing old entry and updating existing video"
    )

    case Reencodarr.Media.delete_video(video) do
      {:ok, _} ->
        Logger.info("Successfully removed old video entry at #{old_path}")
        Reencodarr.Sync.upsert_video_from_file(file, source)

      {:error, reason} ->
        Logger.error("Failed to remove old video entry at #{old_path}: #{inspect(reason)}")
    end
  end

  defp handle_update_result({:error, changeset}, _video, old_path, new_path, _file, _source) do
    Logger.error(
      "Failed to update video path from #{old_path} to #{new_path}: #{inspect(changeset.errors)}"
    )
  end

  defp handle_episodefile(conn, %{"episodeFile" => episode_file}) do
    Logger.info("Received new episodefile event from Sonarr!")
    Reencodarr.Sync.upsert_video_from_file(episode_file, :sonarr)
    send_resp(conn, :no_content, "")
  end

  defp handle_series_add(conn, %{"series" => series} = _params) do
    series_title = series["title"]
    series_id = series["id"]
    Logger.info("Received SeriesAdd event from Sonarr for: #{series_title} (ID: #{series_id})")

    # For now, just log the event. In the future, this could:
    # - Trigger a library scan for the series path
    # - Initialize series tracking in the database
    # - Queue the series for monitoring

    send_resp(conn, :no_content, "")
  end

  defp handle_series_delete(conn, %{"series" => series} = _params) do
    series_title = series["title"]
    series_id = series["id"]
    Logger.info("Received SeriesDelete event from Sonarr for: #{series_title} (ID: #{series_id})")

    # For now, just log the event. In the future, this could:
    # - Remove all videos associated with this series
    # - Clean up any tracking data for the series
    # - Update library statistics

    send_resp(conn, :no_content, "")
  end

  defp handle_unknown(conn, params) do
    Logger.info("Received unsupported event from Sonarr: #{inspect(params["eventType"])}")
    send_resp(conn, :no_content, "ignored")
  end
end
