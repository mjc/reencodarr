defmodule ReencodarrWeb.SonarrWebhookController do
  use ReencodarrWeb, :controller
  require Logger

  def sonarr(conn, %{"eventType" => event} = params) do
    case event do
      "Test" -> handle_test(conn, params)
      "Grab" -> handle_grab(conn, params)
      "Download" -> handle_download(conn, params)
      "EpisodeFileDelete" -> handle_delete(conn, params)
      "Rename" -> handle_rename(conn, params)
      "EpisodeFile" -> handle_episodefile(conn, params)
      _ -> handle_unknown(conn, params)
    end
  end

  defp handle_test(conn, params) do
    dbg(params)
    Logger.info("Received test event from Sonarr!")
    send_resp(conn, :no_content, "")
  end

  defp handle_grab(conn, %{"release" => %{"releaseTitle" => title}}) do
    Logger.info("Received grab event from Sonarr for #{title}!")
    send_resp(conn, :no_content, "")
  end

  defp handle_download(conn, %{"episodeFiles" => episode_files} = params) do
    dbg(params)

    results =
      Enum.map(episode_files, fn file ->
        Logger.info("Received download event from Sonarr for #{file["sceneName"]}!")
        Reencodarr.Sync.upsert_video_from_file(file, :sonarr)
      end)

    if Enum.all?(results, &(&1 == :ok)) do
      Logger.info("Successfully processed download event for Sonarr")
    else
      Logger.error("No successful upserts for download event")
    end

    send_resp(conn, :no_content, "")
  end

  defp handle_delete(conn, %{"episodeFile" => episode_file}) do
    Logger.info("Received delete event from Sonarr for episode file: #{inspect(episode_file)}")
    send_resp(conn, :no_content, "")
  end

  defp handle_rename(conn, %{"renamedEpisodeFiles" => renamed_files}) do
    Logger.info("Received rename event from Sonarr for files: #{inspect(renamed_files)}")

    Enum.each(renamed_files, fn file ->
      dbg(file, label: "Renamed file details")
      Reencodarr.Sync.upsert_video_from_file(file, :sonarr) |> dbg()
    end)

    send_resp(conn, :no_content, "")
  end

  defp handle_episodefile(conn, %{"episodeFile" => episode_file} = params) do
    dbg(params)
    Logger.info("Received new episodefile event from Sonarr!")
    dbg(Reencodarr.Sync.upsert_video_from_file(episode_file, :sonarr))
    send_resp(conn, :no_content, "")
  end

  defp handle_unknown(conn, params) do
    dbg(params, label: "Received Sonarr webhook (other event)")
    Logger.info("Received unsupported event from Sonarr: #{inspect(params["eventType"])}")
    send_resp(conn, :no_content, "ignored")
  end
end
