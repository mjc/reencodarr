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
    |> filter_deprecated_fields()
    |> ensure_library_id()
    |> handle_vmaf_deletion_and_bitrate_preservation()
    |> insert_or_update_video()
  end

  defp normalize_keys_to_strings(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp filter_deprecated_fields(attrs) do
    # Remove deprecated boolean fields that may still come from external services
    attrs
    |> Map.delete("reencoded")
    |> Map.delete("failed")
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
        where: fragment("? LIKE CONCAT(?, '%')", ^path, l.path),
        order_by: [desc: fragment("LENGTH(?)", l.path)],
        limit: 1,
        select: l.id
    )
  end

  defp find_library_id(_), do: nil

  defp handle_vmaf_deletion_and_bitrate_preservation(attrs) do
    path = Map.get(attrs, "path")
    new_values = VideoValidator.extract_comparison_values(attrs)
    being_marked_encoded = VideoValidator.get_attr_value(attrs, "state") == :encoded

    existing_video = get_video_metadata_for_comparison(path)

    # Handle VMAF deletion if needed
    if not being_marked_encoded and
         VideoValidator.should_delete_vmafs?(existing_video, new_values) do
      delete_vmafs_for_video(existing_video.id)
    end

    # Determine if we should preserve bitrate
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
      [:id, :inserted_at]
    else
      [:id, :inserted_at, :bitrate]
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

  defp get_video_metadata_for_comparison(path) do
    Repo.one(
      from v in Video,
        where: v.path == ^path and v.state not in [:encoded, :failed],
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
