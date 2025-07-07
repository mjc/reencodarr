defmodule ReencodarrWeb.RadarrWebhookController do
  use ReencodarrWeb, :controller
  require Logger

  def radarr(conn, %{"eventType" => event} = params) do
    case event do
      "Test" -> handle_test(conn, params)
      "Grab" -> handle_grab(conn, params)
      "Download" -> handle_download(conn, params)
      "MovieFileDelete" -> handle_delete(conn, params)
      "Rename" -> handle_rename(conn, params)
      "MovieFile" -> handle_moviefile(conn, params)
      _ -> handle_unknown(conn, params)
    end
  end

  defp handle_test(conn, _params) do
    Logger.info("Received test event from Radarr!")
    send_resp(conn, :no_content, "")
  end

  defp handle_grab(conn, %{"release" => %{"releaseTitle" => title}}) do
    Logger.debug("Received grab event from Radarr for #{title}!")
    send_resp(conn, :no_content, "")
  end

  defp handle_download(conn, %{"eventType" => "Download"} = params) do
    Logger.debug("Received download event from Radarr for #{inspect(params)}!")

    movie_files = params["movieFiles"] || [params["movieFile"]]

    results =
      Enum.map(movie_files, fn file ->
        scene_name = file["sceneName"] || Path.basename(file["path"])
        Logger.info("Processing file #{scene_name}...")
        Reencodarr.Sync.upsert_video_from_file(file, :radarr)
      end)

    if Enum.all?(results, fn res -> res == :ok or match?({:ok, _}, res) end) do
      Logger.info("Successfully processed download event for Radarr")
    else
      Logger.error("Some upserts failed for download event: #{inspect(results)}")
    end

    send_resp(conn, :no_content, "")
  end

  defp handle_download(conn, params) do
    Logger.error("Unhandled Radarr webhook payload: #{inspect(params)}")
    send_resp(conn, 400, "Unhandled payload")
  end

  defp handle_delete(conn, %{"movieFile" => movie_file}) do
    Logger.info("Received delete event from Radarr for movie file: #{movie_file["relativePath"]}")
    path = movie_file["path"]

    case Reencodarr.Sync.delete_video_and_vmafs(path) do
      :ok ->
        Logger.info("Deleted video and vmafs for path: #{path}")

      {:error, reason} ->
        Logger.error("Failed to delete video and vmafs for path #{path}: #{inspect(reason)}")
    end

    send_resp(conn, :no_content, "")
  end

  defp handle_rename(conn, %{"renamedMovieFiles" => renamed_files}) do
    Logger.debug("Received rename event from Radarr for files: #{inspect(renamed_files)}")

    Enum.each(renamed_files, &update_or_upsert_video(&1, :radarr))

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

    with {:ok, _} <- Reencodarr.Media.delete_video(video) do
      Logger.info("Successfully removed old video entry at #{old_path}")
      Reencodarr.Sync.upsert_video_from_file(file, source)
    else
      {:error, reason} ->
        Logger.error("Failed to remove old video entry at #{old_path}: #{inspect(reason)}")
    end
  end

  defp handle_update_result({:error, changeset}, _video, old_path, new_path, _file, _source) do
    Logger.error(
      "Failed to update video path from #{old_path} to #{new_path}: #{inspect(changeset.errors)}"
    )
  end

  defp handle_moviefile(conn, %{"movieFile" => movie_file}) do
    Logger.info("Received new MovieFile event from Radarr!")
    Reencodarr.Sync.upsert_video_from_file(movie_file, :radarr)
    send_resp(conn, :no_content, "")
  end

  defp handle_unknown(conn, params) do
    Logger.info("Received unsupported event from Radarr: #{inspect(params["eventType"])}")
    send_resp(conn, :no_content, "ignored")
  end
end
