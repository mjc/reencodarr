defmodule Reencodarr.Media.VideoUpsert do
  @moduledoc """
  Handles complex video upsert operations with proper validation and error handling.

  This module extracts the intricate upsert logic from the Media module, including
  attribute normalization, VMAF deletion logic, bitrate preservation, and comprehensive
  error logging.
  """

  require Logger
  import Ecto.Query
  alias Reencodarr.{Media.Library, Media.Video, Media.VideoValidator, Media.Vmaf, Repo}

  @type attrs :: %{String.t() => any()} | %{atom() => any()}
  @type upsert_result :: {:ok, Video.t()} | {:error, Ecto.Changeset.t()} | {:error, any()}

  @doc """
  Upserts a video with complex validation and bitrate preservation logic.
  """
  @spec upsert(attrs()) :: upsert_result()
  def upsert(attrs) do
    # DEBUG: Show what attributes we receive at the start of upsert
    Logger.debug("VideoUpsert received attrs: #{inspect(Map.keys(attrs))}")
    Logger.debug("VideoUpsert size field: #{inspect(Map.get(attrs, "size"))}")

    Logger.debug(
      "VideoUpsert mediainfo field present: #{inspect(Map.has_key?(attrs, "mediainfo"))}"
    )

    with {:ok, normalized_attrs} <- normalize_and_validate_attrs(attrs),
         {:ok, final_attrs, conflict_except} <- prepare_upsert_data(normalized_attrs) do
      perform_upsert(final_attrs, conflict_except, normalized_attrs)
    else
      error -> error
    end
  end

  # Private functions for upsert logic

  defp normalize_and_validate_attrs(attrs) do
    normalized_attrs = normalize_keys_to_strings(attrs)

    # Debug log for atom key detection - check the normalized result
    atom_keys = normalized_attrs |> Map.keys() |> Enum.filter(&is_atom/1)

    if length(atom_keys) > 0 do
      Logger.warning("❌ Still have atom keys after normalization: #{inspect(atom_keys)}")
    end

    {:ok, ensure_library_id(normalized_attrs)}
  end

  defp prepare_upsert_data(attrs) do
    path = Map.get(attrs, "path")
    new_values = VideoValidator.extract_comparison_values(attrs)
    being_marked_reencoded = VideoValidator.get_attr_value(attrs, "reencoded") == true

    existing_video = get_video_metadata_for_comparison(path)

    # Handle VMAF deletion if needed
    if not being_marked_reencoded and
         VideoValidator.should_delete_vmafs?(existing_video, new_values) do
      delete_vmafs_for_video(existing_video.id)
    end

    # Determine if we should preserve bitrate
    preserve_bitrate =
      not being_marked_reencoded and
        VideoValidator.should_preserve_bitrate?(existing_video, new_values)

    {final_attrs, conflict_except} =
      prepare_final_attributes(attrs, preserve_bitrate, existing_video, path)

    {:ok, final_attrs, conflict_except}
  end

  defp prepare_final_attributes(attrs, preserve_bitrate, existing_video, path) do
    if preserve_bitrate do
      Logger.debug(
        "Preserving existing bitrate #{existing_video.bitrate} for path #{path} (same file, different metadata)"
      )

      cleaned_attrs =
        attrs
        |> Map.delete("bitrate")
        |> Map.delete("mediainfo")

      # DEBUG: Check if size is preserved in cleaned_attrs
      Logger.debug("Cleaned attrs for bitrate preservation: #{inspect(Map.keys(cleaned_attrs))}")
      Logger.debug("Size in cleaned attrs: #{inspect(Map.get(cleaned_attrs, "size"))}")

      {cleaned_attrs, [:id, :inserted_at, :reencoded, :failed, :bitrate]}
    else
      if not is_nil(existing_video) do
        Logger.debug(
          "Allowing bitrate update for path #{path}: preserve_bitrate=#{inspect(preserve_bitrate)}"
        )
      end

      # DEBUG: Check if size is in full attrs
      Logger.debug("Full attrs for bitrate update: #{inspect(Map.keys(attrs))}")
      Logger.debug("Size in full attrs: #{inspect(Map.get(attrs, "size"))}")

      {attrs, [:id, :inserted_at, :reencoded, :failed]}
    end
  end

  defp perform_upsert(final_attrs, conflict_except, original_attrs) do
    # Debug: Log state transition attempts for analyzer infinite loop debugging
    log_state_transition_debug(final_attrs)

    result =
      Repo.transaction(fn ->
        # Build the on_conflict query with dateAdded check
        on_conflict_query = build_on_conflict_query(final_attrs, conflict_except)

        changeset = %Video{} |> Video.changeset(final_attrs)

        # Debug: Log changeset validation errors for analyzer infinite loop debugging
        log_changeset_validation_debug(final_attrs, changeset)

        changeset
        |> Repo.insert(
          on_conflict: on_conflict_query,
          conflict_target: :path,
          stale_error_field: :updated_at,
          returning: true
        )
      end)

    handle_upsert_result(result, original_attrs)
  end

  defp log_state_transition_debug(final_attrs) do
    if Map.get(final_attrs, "state") == "analyzed" do
      path = Map.get(final_attrs, "path")
      Logger.debug("🔍 Attempting state transition to 'analyzed' for #{Path.basename(path)}")

      Logger.debug(
        "   Required fields present: bitrate=#{!!Map.get(final_attrs, "bitrate")}, width=#{!!Map.get(final_attrs, "width")}, height=#{!!Map.get(final_attrs, "height")}, duration=#{!!Map.get(final_attrs, "duration")}"
      )

      Logger.debug(
        "   Codecs present: video=#{inspect(Map.get(final_attrs, "video_codecs"))}, audio=#{inspect(Map.get(final_attrs, "audio_codecs"))}"
      )
    end
  end

  defp log_changeset_validation_debug(final_attrs, changeset) do
    if Map.get(final_attrs, "state") == "analyzed" and not changeset.valid? do
      path = Map.get(final_attrs, "path")

      Logger.warning(
        "❌ Changeset validation failed for 'analyzed' state transition: #{Path.basename(path)}"
      )

      Logger.warning("   Validation errors: #{inspect(changeset.errors)}")
    end
  end

  defp handle_upsert_result(result, original_attrs) do
    case result do
      {:ok, {:ok, video}} ->
        Reencodarr.Telemetry.emit_video_upserted(video)
        {:ok, video}

      {:ok, {:error, %Ecto.Changeset{errors: [updated_at: {"is stale", _}]} = changeset}} ->
        handle_stale_update(changeset, original_attrs)

      {:ok, error} ->
        log_upsert_failure(original_attrs, error)
        error

      {:error, _} = error ->
        log_upsert_failure(original_attrs, error)
        error
    end
  end

  defp handle_stale_update(changeset, original_attrs) do
    # This is expected when dateAdded is not newer than updated_at - treat as success (skip)
    path = Map.get(original_attrs, "path")
    Logger.debug("Skipping update for #{path} - dateAdded not newer than updated_at")

    # Return the existing video instead of an error
    case Repo.get_by(Video, path: path) do
      # Shouldn't happen, but handle gracefully
      nil -> {:error, changeset}
      existing_video -> {:ok, existing_video}
    end
  end

  defp build_on_conflict_query(attrs, conflict_except) do
    case Map.get(attrs, "dateAdded") do
      nil ->
        # No dateAdded provided, use normal replace_all_except
        {:replace_all_except, conflict_except}

      date_added_str ->
        # Parse the dateAdded and select the appropriate query
        case parse_date_added(date_added_str) do
          {:ok, date_added} ->
            # Build conditional update with dateAdded check
            build_conditional_update_query(attrs, conflict_except, date_added)

          {:error, _} ->
            # If can't parse dateAdded, fall back to normal behavior
            Logger.warning(
              "Could not parse dateAdded: #{date_added_str}, proceeding with normal upsert"
            )

            {:replace_all_except, conflict_except}
        end
    end
  end

  # Pattern match to build the right query based on whether we have dateAdded
  defp build_conditional_update_query(attrs, conflict_except, date_added) do
    update_fields = build_update_fields(attrs, conflict_except)

    # Build the update but filter by a WHERE condition in on_conflict
    # Use Ecto's support for conditional updates in on_conflict
    update_query =
      from(v in Video,
        update: [set: ^update_fields],
        where: fragment("? > ?", ^date_added, v.updated_at)
      )

    # Return the update query directly - Ecto should handle this
    update_query
  end

  defp build_update_fields(attrs, conflict_except) do
    attrs
    |> Map.to_list()
    |> Enum.reject(fn {key, _} ->
      string_key = to_string(key)
      # Exclude conflict_except fields and dateAdded (which is only used for comparison)
      Enum.any?(conflict_except, &(to_string(&1) == string_key)) or string_key == "dateAdded"
    end)
    |> Enum.map(fn {key, value} -> {String.to_atom(key), value} end)
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

  defp normalize_keys_to_strings(attrs) when is_map(attrs) do
    for {key, value} <- attrs, into: %{} do
      string_key =
        cond do
          is_atom(key) -> Atom.to_string(key)
          is_binary(key) -> key
          true -> to_string(key)
        end

      {string_key, value}
    end
  end

  defp get_video_metadata_for_comparison(path) do
    Repo.one(
      from v in Video,
        where: v.path == ^path and v.reencoded == false and v.failed == false,
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

  defp ensure_library_id(%{"library_id" => nil} = attrs) do
    path = Map.get(attrs, "path")
    Map.put(attrs, "library_id", find_library_id(path))
  end

  defp ensure_library_id(%{"library_id" => _} = attrs), do: attrs

  defp ensure_library_id(attrs) do
    path = Map.get(attrs, "path")
    Map.put(attrs, "library_id", find_library_id(path))
  end

  defp find_library_id(path) when is_binary(path) do
    # Query library that contains this path
    Repo.one(
      from l in Library,
        where: fragment("? LIKE CONCAT(?, '%')", ^path, l.path),
        order_by: [desc: fragment("LENGTH(?)", l.path)],
        limit: 1,
        select: l.id
    )
  end

  defp find_library_id(_), do: nil

  defp log_upsert_failure(attrs, error) do
    path = Map.get(attrs, "path")
    file_exists = File.exists?(path)
    existing_video = Reencodarr.Media.get_video_by_path(path)
    library_id = find_library_id(path)

    error_details = extract_error_details(error)

    failure_info = %{
      path: path,
      success: false,
      operation: "upsert_failed",
      video_id: nil,
      messages: build_diagnostic_messages(file_exists, existing_video, library_id),
      errors: error_details,
      library_id: library_id,
      file_exists: file_exists,
      had_existing_video: !is_nil(existing_video),
      provided_attrs: Map.keys(attrs) |> Enum.sort()
    }

    Logger.warning("❌ Video upsert failed: #{path}")
    Logger.warning("   Failure details: #{inspect(failure_info, pretty: true)}")
  end

  defp extract_error_details(error) do
    case error do
      {:error, %Ecto.Changeset{} = changeset} ->
        changeset.errors
        |> Enum.map(fn {field, {message, _}} -> "#{field}: #{message}" end)

      {:error, reason} ->
        ["Error: #{inspect(reason)}"]

      other ->
        ["Unknown error: #{inspect(other)}"]
    end
  end

  defp build_diagnostic_messages(file_exists, existing_video, library_id) do
    messages = []

    messages =
      if file_exists do
        ["File exists on filesystem" | messages]
      else
        ["File does not exist on filesystem" | messages]
      end

    messages =
      case existing_video do
        nil -> ["No existing video found in database" | messages]
        %Video{id: id} -> ["Found existing video with ID: #{id}" | messages]
      end

    case library_id do
      nil -> ["No matching library found for path" | messages]
      lib_id -> ["Found library ID: #{lib_id}" | messages]
    end
    |> Enum.reverse()
  end
end
