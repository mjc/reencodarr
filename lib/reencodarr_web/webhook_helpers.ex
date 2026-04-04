defmodule ReencodarrWeb.WebhookHelpers do
  @moduledoc """
  Shared helpers for webhook processing across both Sonarr and Radarr controllers.
  Consolidates duplicate validation and update logic.
  """

  require Logger

  # Path, size, and ID validation

  def validate_file_path(path) when is_binary(path) and path != "" do
    if String.trim(path) != "" do
      {:ok, path}
    else
      {:error, "path cannot be empty"}
    end
  end

  def validate_file_path(nil), do: {:error, "path is required"}
  def validate_file_path(_), do: {:error, "path must be a string"}

  def validate_file_size(size) when is_integer(size) and size > 0, do: {:ok, size}
  def validate_file_size(nil), do: {:error, "size is required"}
  def validate_file_size(_), do: {:error, "size must be a positive integer"}

  def validate_file_id(id) when is_binary(id) or is_integer(id), do: {:ok, id}
  def validate_file_id(_), do: {:error, "file id is required"}

  # Video update and rename handling

  def update_or_upsert_video(%{"previousPath" => old_path, "path" => new_path} = file, source) do
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

  def handle_update_result({:ok, _}, _video, old_path, new_path, _file, _source) do
    Logger.info("Updated video path from #{old_path} to #{new_path}")
  end

  def handle_update_result(
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

  def handle_update_result({:error, changeset}, _video, old_path, new_path, _file, _source) do
    Logger.error(
      "Failed to update video path from #{old_path} to #{new_path}: #{inspect(changeset.errors)}"
    )
  end
end
