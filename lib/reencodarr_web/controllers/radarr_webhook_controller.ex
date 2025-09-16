defmodule ReencodarrWeb.RadarrWebhookController do
  use ReencodarrWeb, :controller
  require Logger

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

    results =
      Enum.map(movie_files, fn file ->
        case validate_movie_file(file) do
          {:ok, validated_file} ->
            process_valid_movie_file(validated_file)

          {:error, reason} ->
            Logger.error("Invalid movie file data from Radarr: #{reason}")
            {:error, reason}
        end
      end)

    if Enum.all?(results, fn res -> match?({:ok, _}, res) end) do
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
      {:error, :not_found} ->
        Logger.warning("No video found for old path: #{old_path}, upserting as new")
        Reencodarr.Sync.upsert_video_from_file(file, source)

      {:ok, video} ->
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

    case Reencodarr.Media.delete_video_with_vmafs(video) do
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

  defp handle_moviefile(conn, %{"movieFile" => movie_file}) do
    Logger.info("Received new MovieFile event from Radarr!")
    Reencodarr.Sync.upsert_video_from_file(movie_file, :radarr)
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
    Logger.info("Received MovieDelete event from Radarr for: #{movie_title} (ID: #{movie_id})")

    # For now, just log the event. In the future, this could:
    # - Remove all videos associated with this movie
    # - Clean up any tracking data for the movie
    # - Update library statistics

    send_resp(conn, :no_content, "")
  end

  defp handle_unknown(conn, params) do
    Logger.info("Received unsupported event from Radarr: #{inspect(params["eventType"])}")
    send_resp(conn, :no_content, "ignored")
  end

  # Validation functions

  defp validate_movie_file(file) when is_map(file) do
    with {:ok, path} <- validate_file_path(file["path"]),
         {:ok, size} <- validate_file_size(file["size"]),
         {:ok, id} <- validate_file_id(file["id"] || file["movieFileId"]) do
      {:ok, %{path: path, size: size, id: id, raw_file: file}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_movie_file(_), do: {:error, "movie file must be a map"}

  defp validate_file_path(path) when is_binary(path) and path != "" do
    if String.trim(path) != "" do
      {:ok, path}
    else
      {:error, "path cannot be empty"}
    end
  end

  defp validate_file_path(nil), do: {:error, "path is required"}
  defp validate_file_path(_), do: {:error, "path must be a string"}

  defp validate_file_size(size) when is_integer(size) and size > 0, do: {:ok, size}
  defp validate_file_size(nil), do: {:error, "size is required"}
  defp validate_file_size(_), do: {:error, "size must be a positive integer"}

  defp validate_file_id(id) when is_binary(id) or is_integer(id), do: {:ok, id}
  defp validate_file_id(_), do: {:error, "file id is required"}

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
end
