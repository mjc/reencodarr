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
    Logger.info("Received grab event from Radarr for #{title}!")
    send_resp(conn, :no_content, "")
  end

  defp handle_download(conn, %{"eventType" => "Download"} = params) do
    Logger.debug("Received download event from Radarr for #{inspect(params)}!")

    movie_files = params["movieFiles"] || [params["movieFile"]]

    results =
      Enum.map(movie_files, fn file ->
        Logger.info("Processing file #{file["sceneName"]}...")
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
        {:ok, _} = Reencodarr.Media.update_video(video, %{path: new_path})
        Logger.info("Updated video path from #{old_path} to #{new_path}")
    end
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
