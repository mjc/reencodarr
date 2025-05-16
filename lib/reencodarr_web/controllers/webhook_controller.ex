defmodule ReencodarrWeb.WebhookController do
  use ReencodarrWeb, :controller
  require Logger

  def sonarr(conn, %{"eventType" => "Test" = event_type} = params) do
    dbg(params, label: "Received Sonarr webhook")
    Logger.debug("Received test event from Sonarr!")
    send_resp(conn, 200, "ok")
  end

  def sonarr(conn, %{"eventType" => "EpisodeFile", "episodeFile" => episode_file} = params) do
    dbg(params, label: "Received Sonarr webhook")
    Logger.debug("Received new episodefile event from Sonarr!")
    dbg(Reencodarr.Sync.upsert_video_from_file(episode_file, :sonarr))
    send_resp(conn, 200, "ok")
  end

  def sonarr(conn, params) do
    dbg(params, label: "Received Sonarr webhook (other event)")
    Logger.debug("Received unsupported event from Sonarr: #{inspect(params["eventType"])}")
    send_resp(conn, 200, "ignored")
  end
end
