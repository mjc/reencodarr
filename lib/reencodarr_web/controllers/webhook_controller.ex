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

    results =
      Enum.map(episode_files, fn episode_file ->
        Logger.info(
          "Received download event from Sonarr for episode #{episode_file["sceneName"]}!"
        )

        Reencodarr.Sync.upsert_video_from_file(episode_file, :sonarr)
      end)

    case Enum.all?(results, &(&1 == :ok)) do
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

  def radarr(conn, %{"eventType" => "Test"} = params) do
    dbg(params)
    Logger.info("Received test event from Radarr!")
    send_resp(conn, :no_content, "")
  end

  def radarr(conn, %{"eventType" => "Grab", "release" => %{"releaseTitle" => title}} = _params) do
    Logger.info("Received grab event from Radarr for #{title}!")
    send_resp(conn, :no_content, "")
  end

  def radarr(conn, %{"eventType" => "Download", "movieFiles" => movie_files} = params) do
    dbg(params)

    results =
      Enum.map(movie_files, fn movie_file ->
        Logger.info(
          "Received download event from Radarr for movie #{movie_file["sceneName"]}!"
        )

        Reencodarr.Sync.upsert_video_from_file(movie_file, :radarr)
      end)

    case Enum.all?(results, &(&1 == :ok)) do
      [] -> Logger.error("No successful upserts for download event")
      _ -> Logger.info("Successfully processed download event for Radarr")
    end

    send_resp(conn, :no_content, "")
  end

  def radarr(conn, %{"eventType" => "MovieFileDelete", "movieFile" => movie_file} = _params) do
    Logger.info("Received delete event from Radarr for movie file: #{inspect(movie_file)}")
    send_resp(conn, :no_content, "")
  end

  def radarr(conn, %{"eventType" => "Rename", "renamedMovieFiles" => renamed_files} = _params) do
    Logger.info("Received rename event from Radarr for files: #{inspect(renamed_files)}")

    renamed_files
    |> Enum.each(fn file ->
      dbg(file, label: "Renamed file details")
      Reencodarr.Sync.upsert_video_from_file(file, :radarr) |> dbg()
    end)

    send_resp(conn, :no_content, "")
  end

  def radarr(conn, %{"eventType" => "MovieFile", "movieFile" => movie_file} = params) do
    dbg(params)
    Logger.info("Received new MovieFile event from Radarr!")
    dbg(Reencodarr.Sync.upsert_video_from_file(movie_file, :radarr))
    send_resp(conn, :no_content, "")
  end

  def radarr(conn, params) do
    dbg(params, label: "Received Radarr webhook (other event)")
    Logger.info("Received unsupported event from Radarr: #{inspect(params["eventType"])}")
    send_resp(conn, :no_content, "ignored")
  end
end
