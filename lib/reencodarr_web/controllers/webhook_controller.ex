defmodule ReencodarrWeb.WebhookController do
  use ReencodarrWeb, :controller
  require Logger

  def sonarr(conn, %{"eventType" => "Test"} = params) do
    dbg(params)
    Logger.info("Received test event from Sonarr!")
    send_resp(conn, :no_content, "")
  end

  def sonarr(conn, %{"eventType" => "Grab", "release" => %{"releaseTitle" => title}} = _params) do
    Logger.info("Received grab event from Sonarr for #{title}!")
    send_resp(conn, :no_content, "")
  end

  def sonarr(conn, %{"eventType" => "Download", "episodeFiles" => episode_files} = params) do
    dbg(params)
    results = Enum.map(episode_files, fn episode_file ->
      Logger.info("Received download event from Sonarr for episode #{episode_file["sceneName"]}!")
      Reencodarr.Sync.upsert_video_from_file(episode_file, :sonarr)
    end)
    case Keyword.get_values(results, :ok) do
      [] -> Logger.error("No successful upserts for download event")
      _ -> Logger.info("Successfully processed download event for Sonarr")
    end
    send_resp(conn, :no_content, "")
  end

  def sonarr(conn, %{"eventType" => "EpisodeFileDelete", "episodeFile" => episode_file} = _params) do
    Logger.info("Received delete event from Sonarr for episode file: #{inspect(episode_file)}")
    send_resp(conn, :no_content, "")
  end

  def sonarr(conn, %{"eventType" => "Rename", "renamedEpisodeFiles" => renamed_files} = _params) do
    Logger.info("Received rename event from Sonarr for files: #{inspect(renamed_files)}")

    renamed_files
    |> Enum.each(fn file ->
      dbg(file, label: "Renamed file details")
      Reencodarr.Sync.upsert_video_from_file(file, :sonarr) |> dbg()
    end)

    send_resp(conn, :no_content, "")
  end

  def sonarr(conn, %{"eventType" => "EpisodeFile", "episodeFile" => episode_file} = params) do
    dbg(params)
    Logger.info("Received new episodefile event from Sonarr!")
    dbg(Reencodarr.Sync.upsert_video_from_file(episode_file, :sonarr))
    send_resp(conn, :no_content, "")
  end

  def sonarr(conn, params) do
    dbg(params, label: "Received Sonarr webhook (other event)")
    Logger.info("Received unsupported event from Sonarr: #{inspect(params["eventType"])}")
    send_resp(conn, :no_content, "ignored")
  end
end
