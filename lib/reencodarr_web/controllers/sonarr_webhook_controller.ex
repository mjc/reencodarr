defmodule ReencodarrWeb.SonarrWebhookController do
  use ReencodarrWeb, :controller
  require Logger
  alias ReencodarrWeb.WebhookHelpers

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
    ReencodarrWeb.WebhookProcessor.queue(fn -> process_episode_downloads(episode_files) end)
    send_resp(conn, :no_content, "")
  end

  defp handle_download(conn, %{"episodeFile" => episode_file} = _params)
       when is_map(episode_file) do
    ReencodarrWeb.WebhookProcessor.queue(fn -> process_validated_episode_file(episode_file) end)
    send_resp(conn, :no_content, "")
  end

  defp handle_delete(conn, %{"episodeFile" => episode_file}) do
    Logger.info("Received delete event from Sonarr for episode file: #{inspect(episode_file)}")
    path = episode_file["path"]
    ReencodarrWeb.WebhookProcessor.queue(fn -> process_episode_delete(path) end)
    send_resp(conn, :no_content, "")
  end

  defp process_episode_delete(path) do
    case Reencodarr.Sync.delete_video_and_vmafs(path) do
      :ok ->
        Logger.info("Deleted video and vmafs for path: #{path}")

      {:error, reason} ->
        Logger.error("Failed to delete video and vmafs for path #{path}: #{inspect(reason)}")
    end
  end

  defp handle_rename(conn, %{"renamedEpisodeFiles" => renamed_files}) do
    Logger.debug("Received rename event from Sonarr for files: #{inspect(renamed_files)}")
    ReencodarrWeb.WebhookProcessor.queue(fn -> process_episode_renames(renamed_files) end)
    send_resp(conn, :no_content, "")
  end

  defp process_episode_renames(files) do
    Enum.each(files, &WebhookHelpers.update_or_upsert_video(&1, :sonarr))
  end

  defp handle_episodefile(conn, %{"episodeFile" => episode_file}) do
    Logger.info("Received new episodefile event from Sonarr!")
    ReencodarrWeb.WebhookProcessor.queue(fn -> process_episode_file(episode_file) end)
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
    series_path = series["path"]

    Logger.info("Received SeriesDelete event from Sonarr for: #{series_title} (ID: #{series_id})")

    ReencodarrWeb.WebhookProcessor.queue(fn ->
      process_series_delete(series_path, series_title)
    end)

    send_resp(conn, :no_content, "")
  end

  defp handle_unknown(conn, params) do
    Logger.info("Received unsupported event from Sonarr: #{inspect(params["eventType"])}")
    send_resp(conn, :no_content, "ignored")
  end

  # Validation functions

  defp validate_episode_file(file) when is_map(file) do
    with {:ok, path} <- WebhookHelpers.validate_file_path(file["path"]),
         {:ok, size} <- WebhookHelpers.validate_file_size(file["size"]),
         {:ok, id} <- WebhookHelpers.validate_file_id(file["id"]) do
      scene_name = file["sceneName"] || Path.basename(path)
      {:ok, %{path: path, size: size, id: id, scene_name: scene_name, raw_file: file}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_episode_file(_), do: {:error, "episode file must be a map"}

  # Async background task functions

  defp process_episode_downloads(files) do
    Enum.each(files, &process_validated_episode_file/1)
  end

  defp process_validated_episode_file(file) do
    case validate_episode_file(file) do
      {:ok, validated_file} ->
        scene_name = validated_file.scene_name
        Logger.info("Received download event from Sonarr for #{scene_name}!")

        validated_file.raw_file
        |> Reencodarr.Sync.upsert_video_from_file(:sonarr)
        |> ReencodarrWeb.WebhookProcessor.reconcile_waiting_bad_file_issues(:sonarr)

      {:error, reason} ->
        Logger.error("Invalid episode file data from Sonarr: #{reason}")
    end
  end

  defp process_episode_file(file) do
    file
    |> Reencodarr.Sync.upsert_video_from_file(:sonarr)
    |> ReencodarrWeb.WebhookProcessor.reconcile_waiting_bad_file_issues(:sonarr)
  end

  defp process_series_delete(series_path, _series_title)
       when is_binary(series_path) and series_path != "" do
    case Reencodarr.Media.delete_videos_under_path(series_path) do
      {:ok, 0} ->
        Logger.info("SeriesDelete: no videos found under #{series_path}")

      {:ok, count} ->
        Logger.info("SeriesDelete: deleted #{count} videos under #{series_path}")

      {:error, reason} ->
        Logger.error(
          "SeriesDelete: failed to delete videos under #{series_path}: #{inspect(reason)}"
        )
    end
  end

  defp process_series_delete(_series_path, series_title) do
    Logger.warning("SeriesDelete: no path in webhook payload for #{series_title}")
  end
end
