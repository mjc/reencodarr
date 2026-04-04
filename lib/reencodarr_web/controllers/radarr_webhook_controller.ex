defmodule ReencodarrWeb.RadarrWebhookController do
  use ReencodarrWeb, :controller
  require Logger
  alias ReencodarrWeb.WebhookHelpers

  def radarr(conn, %{"eventType" => "Test"} = params), do: handle_test(conn, params)
  def radarr(conn, %{"eventType" => "Grab"} = params), do: handle_grab(conn, params)
  def radarr(conn, %{"eventType" => "Download"} = params), do: handle_download(conn, params)
  def radarr(conn, %{"eventType" => "MovieFileDelete"} = params), do: handle_delete(conn, params)
  def radarr(conn, %{"eventType" => "Rename"} = params), do: handle_rename(conn, params)
  def radarr(conn, %{"eventType" => "MovieFile"} = params), do: handle_moviefile(conn, params)
  def radarr(conn, %{"eventType" => "MovieAdd"} = params), do: handle_movie_add(conn, params)

  def radarr(conn, %{"eventType" => "MovieDelete"} = params),
    do: handle_movie_delete(conn, params)

  def radarr(conn, params), do: handle_unknown(conn, params)

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
    ReencodarrWeb.WebhookProcessor.queue(fn -> process_movie_downloads(movie_files) end)
    send_resp(conn, :no_content, "")
  end

  defp handle_download(conn, params) do
    Logger.error("Unhandled Radarr webhook payload: #{inspect(params)}")
    send_resp(conn, :no_content, "")
  end

  defp handle_delete(conn, %{"movieFile" => movie_file}) do
    Logger.info("Received delete event from Radarr for movie file: #{movie_file["relativePath"]}")
    path = movie_file["path"]
    ReencodarrWeb.WebhookProcessor.queue(fn -> process_movie_delete_by_path(path) end)
    send_resp(conn, :no_content, "")
  end

  defp handle_rename(conn, %{"renamedMovieFiles" => renamed_files}) do
    Logger.debug("Received rename event from Radarr for files: #{inspect(renamed_files)}")
    ReencodarrWeb.WebhookProcessor.queue(fn -> process_movie_renames(renamed_files) end)
    send_resp(conn, :no_content, "")
  end

  defp handle_moviefile(conn, %{"movieFile" => movie_file}) do
    Logger.info("Received new MovieFile event from Radarr!")
    ReencodarrWeb.WebhookProcessor.queue(fn -> process_movie_file(movie_file) end)
    send_resp(conn, :no_content, "")
  end

  defp handle_movie_add(conn, %{"movie" => movie} = _params) do
    movie_title = movie["title"]
    movie_id = movie["id"]
    Logger.info("Received MovieAdd event from Radarr for: #{movie_title} (ID: #{movie_id})")

    # For now, just log the event. In the future, this could:
    # - Trigger a library scan for the movie path
    # - Initialize movie tracking in the database
    # - Queue the movie for monitoring

    send_resp(conn, :no_content, "")
  end

  defp handle_movie_delete(conn, %{"movie" => movie} = _params) do
    movie_title = movie["title"]
    movie_id = movie["id"]
    movie_path = movie["folderPath"] || movie["path"]

    Logger.info("Received MovieDelete event from Radarr for: #{movie_title} (ID: #{movie_id})")
    ReencodarrWeb.WebhookProcessor.queue(fn -> process_movie_folder_delete(movie_path, movie_title) end)
    send_resp(conn, :no_content, "")
  end

  defp handle_unknown(conn, params) do
    Logger.info("Received unsupported event from Radarr: #{inspect(params["eventType"])}")
    send_resp(conn, :no_content, "ignored")
  end

  # Validation functions

  defp validate_movie_file(file) when is_map(file) do
    with {:ok, path} <- WebhookHelpers.validate_file_path(file["path"]),
         {:ok, size} <- WebhookHelpers.validate_file_size(file["size"]),
         {:ok, id} <- WebhookHelpers.validate_file_id(file["id"] || file["movieFileId"]) do
      {:ok, %{path: path, size: size, id: id, raw_file: file}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_movie_file(_), do: {:error, "movie file must be a map"}

  defp process_valid_movie_file(%{path: path, size: size, id: id, raw_file: file}) do
    scene_name = file["sceneName"] || Path.basename(path)
    Logger.info("Processing file #{scene_name}...")

    # Create basic video record without mediainfo - analysis will handle that
    attrs = %{
      "path" => path,
      "size" => size,
      # Force analysis state
      "state" => :needs_analysis,
      "service_id" => to_string(id),
      "service_type" => "radarr",
      # Can be updated by analyzer
      "content_year" => DateTime.utc_now().year,
      # Default values for required fields (will be updated during analysis)
      "video_codecs" => [],
      "audio_codecs" => []
    }

    case Reencodarr.Media.upsert_video(attrs) do
      {:ok, video} ->
        # Delete any existing VMAFs for this path since we're re-analyzing
        Reencodarr.Media.delete_vmafs_for_video(video.id)
        {:ok, video}

      error ->
        error
    end
  end

  # Async background task functions

  defp process_movie_downloads(files) do
    Enum.each(files, &process_validated_movie_file/1)
  end

  defp process_validated_movie_file(file) do
    case validate_movie_file(file) do
      {:ok, validated_file} ->
        validated_file
        |> process_valid_movie_file()
        |> ReencodarrWeb.WebhookProcessor.reconcile_waiting_bad_file_issues(:radarr)

      {:error, reason} ->
        Logger.error("Invalid movie file data from Radarr: #{reason}")
    end
  end

  defp process_movie_delete_by_path(path) do
    case Reencodarr.Sync.delete_video_and_vmafs(path) do
      :ok ->
        Logger.info("Deleted video and vmafs for path: #{path}")

      {:error, reason} ->
        Logger.error("Failed to delete video and vmafs for path #{path}: #{inspect(reason)}")
    end
  end

  defp process_movie_renames(files) do
    Enum.each(files, &WebhookHelpers.update_or_upsert_video(&1, :radarr))
  end

  defp process_movie_file(file) do
    file
    |> Reencodarr.Sync.upsert_video_from_file(:radarr)
    |> ReencodarrWeb.WebhookProcessor.reconcile_waiting_bad_file_issues(:radarr)
  end

  defp process_movie_folder_delete(movie_path, _movie_title)
       when is_binary(movie_path) and movie_path != "" do
    case Reencodarr.Media.delete_videos_under_path(movie_path) do
      {:ok, 0} ->
        Logger.info("MovieDelete: no videos found under #{movie_path}")

      {:ok, count} ->
        Logger.info("MovieDelete: deleted #{count} videos under #{movie_path}")

      {:error, reason} ->
        Logger.error(
          "MovieDelete: failed to delete videos under #{movie_path}: #{inspect(reason)}"
        )
    end
  end

  defp process_movie_folder_delete(_movie_path, movie_title) do
    Logger.warning("MovieDelete: no path in webhook payload for #{movie_title}")
  end
end
