defmodule ReencodarrWeb.WebhookController do
  use ReencodarrWeb, :controller
  require Logger

  def sonarr(conn, %{"eventType" => "Test"} = params) do
    dbg(params, label: "Received Sonarr webhook")
    Logger.info("Received test event from Sonarr!")
    send_resp(conn, 200, "ok")
  end

  def sonarr(conn, %{"eventType" => "Grab", "release" => %{"releaseTitle" => title}} = _params) do
    Logger.info("Received grab event from Sonarr for #{title}!")
    send_resp(conn, 200, "ok")
  end

  def sonarr(conn, %{"eventType" => "EpisodeFile", "episodeFile" => episode_file} = params) do
    dbg(params, label: "Received Sonarr webhook")
    Logger.info("Received new episodefile event from Sonarr!")
    dbg(Reencodarr.Sync.upsert_video_from_file(episode_file, :sonarr))
    send_resp(conn, 200, "ok")
  end

  def sonarr(conn, params) do
    dbg(params, label: "Received Sonarr webhook (other event)")
    Logger.info("Received unsupported event from Sonarr: #{inspect(params["eventType"])}")
    send_resp(conn, 200, "ignored")
  end
end
