defmodule Reencodarr.Media.VideoUpsert do
  @moduledoc """
  Simplified video upsert operations with direct validation and error handling.

  This module provides a streamlined approach to video upserts, consolidating
  validation, attribute preparation, and database operations into a more
  direct and maintainable implementation.
  """

  require Logger
  import Ecto.Query
  alias Reencodarr.{Media.Library, Media.Video, Media.VideoValidator, Media.Vmaf, Repo}

  @type attrs :: %{String.t() => any()} | %{atom() => any()}
  @type upsert_result :: {:ok, Video.t()} | {:error, Ecto.Changeset.t()} | {:error, any()}

  @doc """
  Upserts a video with validation and bitrate preservation logic.
  """
  @spec upsert(attrs()) :: upsert_result()
  def upsert(attrs) do
    Logger.debug("VideoUpsert processing: #{inspect(Map.get(attrs, "path"))}")

    attrs
    |> normalize_keys_to_strings()
    |> ensure_library_id()
    |> ensure_required_fields()
    |> handle_vmaf_deletion_and_bitrate_preservation()
    |> insert_or_update_video()
  end

  @doc """
  Batch upsert multiple videos in a single transaction.
  Returns a list of results, one for each video in the same order.
  """
  @spec batch_upsert([attrs()]) :: [upsert_result()]
  def batch_upsert(video_attrs_list) when is_list(video_attrs_list) do
    Logger.debug("VideoUpsert batch processing #{length(video_attrs_list)} videos")

    Repo.transaction(fn ->
      Enum.map(video_attrs_list, fn attrs ->
        attrs
        |> normalize_keys_to_strings()
        |> ensure_library_id()
        |> ensure_required_fields()
        |> handle_vmaf_deletion_and_bitrate_preservation()
        |> perform_single_upsert_in_batch()
      end)
    end)
    |> case do
      {:ok, results} ->
        results

      {:error, reason} ->
        Logger.error("Batch upsert transaction failed: #{inspect(reason)}")
        # Return error for each video
        Enum.map(video_attrs_list, fn _ -> {:error, reason} end)
    end
  end

  defp normalize_keys_to_strings(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp ensure_library_id(attrs) do
    case Map.get(attrs, "library_id") do
      nil ->
        path = Map.get(attrs, "path")
        library_id = find_library_id(path)
        Map.put(attrs, "library_id", library_id)

      _library_id ->
        attrs
    end
  end

  defp find_library_id(path) when is_binary(path) do
    Repo.one(
      from l in Library,
        where: fragment("? LIKE ? || '%'", ^path, l.path),
        order_by: [desc: fragment("LENGTH(?)", l.path)],
        limit: 1,
        select: l.id
    )
  end

  defp find_library_id(_), do: nil

  # Ensures required fields have default values when not provided.
  # Added to handle sync operations that may not include MediaInfo-derived fields.
  defp ensure_required_fields(attrs) do
    attrs
    |> Map.put_new("max_audio_channels", 6)
    |> Map.put_new("atmos", false)
  end

  defp handle_vmaf_deletion_and_bitrate_preservation(attrs) do
    path = Map.get(attrs, "path")

    # Skip metadata comparison if path is invalid - let validation handle it
    if not is_binary(path) or String.trim(path) == "", do: attrs

    process_video_metadata_changes(attrs, path)
  end

  defp process_video_metadata_changes(attrs, path) do
    new_values = VideoValidator.extract_comparison_values(attrs)
    being_marked_encoded = VideoValidator.get_attr_value(attrs, "state") == "encoded"
    existing_video = get_video_metadata_for_comparison(path)

    # Handle VMAF deletion if needed
    maybe_delete_vmafs(existing_video, new_values, being_marked_encoded)

    # Handle bitrate preservation
    handle_bitrate_preservation(attrs, existing_video, new_values, being_marked_encoded, path)
  end

  defp maybe_delete_vmafs(existing_video, new_values, being_marked_encoded) do
    if not being_marked_encoded and
         VideoValidator.should_delete_vmafs?(existing_video, new_values) do
      delete_vmafs_for_video(existing_video.id)
    end
  end

  defp handle_bitrate_preservation(attrs, existing_video, new_values, being_marked_encoded, path) do
    preserve_bitrate =
      not being_marked_encoded and
        VideoValidator.should_preserve_bitrate?(existing_video, new_values)

    if preserve_bitrate do
      Logger.debug(
        "Preserving existing bitrate #{existing_video.bitrate} for #{path} (same file, different metadata)"
      )

      attrs
      |> Map.delete("bitrate")
      |> Map.delete("mediainfo")
    else
      if not is_nil(existing_video) do
        Logger.debug("Allowing bitrate update for #{path}")
      end

      attrs
    end
  end

  defp insert_or_update_video(attrs) do
    conflict_except = determine_conflict_except_fields(attrs)
    on_conflict_query = build_on_conflict_query(attrs, conflict_except)

    attrs
    |> perform_video_upsert(on_conflict_query)
    |> handle_upsert_result(attrs)
  end

  defp determine_conflict_except_fields(attrs) do
    if Map.has_key?(attrs, "bitrate") do
      [:id, :inserted_at, :state, :failed]
    else
      [:id, :inserted_at, :state, :failed, :bitrate]
    end
  end

  defp build_on_conflict_query(attrs, conflict_except) do
    case Map.get(attrs, "dateAdded") do
      nil ->
        {:replace_all_except, conflict_except}

      date_str when is_binary(date_str) ->
        case parse_date_added(date_str) do
          {:ok, date_added} -> build_conditional_update(attrs, conflict_except, date_added)
          {:error, _} -> {:replace_all_except, conflict_except}
        end

      _ ->
        {:replace_all_except, conflict_except}
    end
  end

  defp perform_video_upsert(attrs, on_conflict_query) do
    Repo.transaction(fn ->
      %Video{}
      |> Video.changeset(attrs)
      |> Repo.insert(
        on_conflict: on_conflict_query,
        conflict_target: :path,
        stale_error_field: :updated_at,
        returning: true
      )
    end)
  end

  defp perform_single_upsert_in_batch(attrs) do
    conflict_except = determine_conflict_except_fields(attrs)
    on_conflict_query = build_on_conflict_query(attrs, conflict_except)

    result =
      %Video{}
      |> Video.changeset(attrs)
      |> Repo.insert(
        on_conflict: on_conflict_query,
        conflict_target: :path,
        stale_error_field: :updated_at,
        returning: true
      )

    case result do
      {:ok, video} ->
        Logger.debug("Successfully upserted video in batch: #{video.path}")
        {:ok, video}

      {:error, %Ecto.Changeset{errors: [updated_at: {"is stale", _}]} = changeset} ->
        handle_stale_update_error_in_batch(changeset, attrs)

      {:error, changeset} ->
        path = Map.get(attrs, "path", "unknown")
        Logger.error("Failed to upsert video in batch #{path}: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  defp handle_stale_update_error_in_batch(changeset, attrs) do
    # This is expected when dateAdded is not newer than updated_at - treat as success (skip)
    path = Map.get(attrs, "path")
    Logger.debug("Skipping update for #{path} in batch - dateAdded not newer than updated_at")

    # Return the existing video instead of an error
    case Repo.get_by(Video, path: path) do
      # Shouldn't happen, but handle gracefully
      nil -> {:error, changeset}
      existing_video -> {:ok, existing_video}
    end
  end

  defp handle_upsert_result(transaction_result, attrs) do
    case transaction_result do
      {:ok, {:ok, video}} ->
        Logger.debug("Video upserted successfully: #{video.path}")
        {:ok, video}

      {:ok, {:error, %Ecto.Changeset{errors: [updated_at: {"is stale", _}]} = changeset}} ->
        handle_stale_update_error(changeset, attrs)

      {:ok, {:error, changeset}} ->
        Logger.error("Video upsert failed: #{inspect(changeset.errors)}")
        {:error, changeset}

      {:error, error} ->
        Logger.error("Video upsert transaction failed: #{inspect(error)}")
        {:error, error}
    end
  end

  defp handle_stale_update_error(changeset, attrs) do
    # This is expected when dateAdded is not newer than updated_at - treat as success (skip)
    path = Map.get(attrs, "path")
    Logger.debug("Skipping update for #{path} - dateAdded not newer than updated_at")

    # Return the existing video instead of an error
    case Repo.get_by(Video, path: path) do
      # Shouldn't happen, but handle gracefully
      nil -> {:error, changeset}
      existing_video -> {:ok, existing_video}
    end
  end

  defp build_conditional_update(attrs, conflict_except, date_added) do
    update_fields =
      attrs
      |> Map.to_list()
      |> Enum.reject(fn {key, _} ->
        string_key = to_string(key)
        Enum.any?(conflict_except, &(to_string(&1) == string_key)) or string_key == "dateAdded"
      end)
      |> Enum.map(fn {key, value} -> {String.to_atom(key), value} end)

    from(v in Video,
      update: [set: ^update_fields],
      where: fragment("? > ?", ^date_added, v.updated_at)
    )
  end

  defp parse_date_added(date_string) when is_binary(date_string) do
    case DateTime.from_iso8601(date_string) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _} = error -> error
    end
  end

  defp parse_date_added(_), do: {:error, :invalid_format}

  defp delete_vmafs_for_video(video_id) do
    from(v in Vmaf, where: v.video_id == ^video_id) |> Repo.delete_all()
  end

  defp get_video_metadata_for_comparison(path) when is_binary(path) do
    Repo.one(
      from v in Video,
        where: v.path == ^path and v.state != :encoded and v.state != :failed,
        select: %{
          id: v.id,
          size: v.size,
          bitrate: v.bitrate,
          duration: v.duration,
          video_codecs: v.video_codecs,
          audio_codecs: v.audio_codecs
        }
    )
  end
end
