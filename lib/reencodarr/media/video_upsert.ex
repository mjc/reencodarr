defmodule Reencodarr.Media.VideoUpsert do
  @moduledoc """
  Simplified video upsert operations with direct validation and error handling.

  This module provides a streamlined approach to video upserts, consolidating
  validation, attribute preparation, and database operations into a more
  direct and maintainable implementation.
  """

  require Logger
  import Ecto.Query
  alias Reencodarr.Core.Retry
  alias Reencodarr.{DbWriter, Media.Library, Media.Video, Media.VideoValidator, Media.Vmaf, Repo}
  alias Reencodarr.Media.VideoStateMachine

  @type attrs :: %{String.t() => any()} | %{atom() => any()}
  @type upsert_result :: {:ok, Video.t()} | {:error, Ecto.Changeset.t()} | {:error, any()}

  @doc """
  Upserts a video with validation and bitrate preservation logic.
  """
  @spec upsert(attrs()) :: upsert_result()
  def upsert(attrs) do
    DbWriter.transaction(
      fn ->
        case do_upsert(attrs) do
          {:ok, video} ->
            video

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end,
      label: "perform video upsert"
    )
    |> case do
      {:ok, video} -> {:ok, video}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Batch upsert multiple videos using per-video transactions.
  Returns a list of results, one for each video in the same order.
  """
  @spec batch_upsert([attrs()]) :: [upsert_result()]
  def batch_upsert(video_attrs_list) when is_list(video_attrs_list) do
    batch_upsert(video_attrs_list, [])
  end

  @spec batch_upsert([attrs()], keyword()) :: [upsert_result()]
  def batch_upsert(video_attrs_list, opts) when is_list(video_attrs_list) and is_list(opts) do
    writer_opts =
      [label: :video_batch_upsert, max_attempts: 1]
      |> Keyword.merge(opts)

    DbWriter.run(
      fn ->
        Logger.debug("VideoUpsert batch processing #{length(video_attrs_list)} videos")
        Enum.map(video_attrs_list, &process_single_video_in_batch/1)
      end,
      writer_opts
    )
  end

  defp do_upsert(attrs) do
    Logger.debug("VideoUpsert processing: #{inspect(Map.get(attrs, "path"))}")

    normalized_attrs = attrs |> normalize_keys_to_strings() |> ensure_library_id()

    old_video =
      Reencodarr.Media.fetch_dashboard_video_snapshot_by_path(Map.get(normalized_attrs, "path"))

    normalized_attrs
    |> ensure_required_fields()
    |> handle_vmaf_deletion_and_bitrate_preservation()
    |> insert_or_update_video(old_video)
  end

  @spec process_single_video_in_batch(attrs()) :: upsert_result()
  defp process_single_video_in_batch(attrs) do
    normalized_attrs =
      attrs
      |> normalize_keys_to_strings()
      |> ensure_library_id()
      |> ensure_required_fields()

    old_video =
      Reencodarr.Media.fetch_dashboard_video_snapshot_by_path(Map.get(normalized_attrs, "path"))

    Retry.retry_on_db_busy(
      fn ->
        Repo.transaction(fn ->
          normalized_attrs
          |> handle_vmaf_deletion_and_bitrate_preservation()
          |> perform_single_upsert_in_batch(old_video)
        end)
      end,
      label: "video upsert transaction"
    )
    |> case do
      {:ok, result} ->
        result

      {:error, reason} ->
        path = Map.get(normalized_attrs, "path", "unknown")
        Logger.error("Batch upsert failed for #{path} after retries: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec normalize_keys_to_strings(attrs()) :: %{String.t() => any()}
  defp normalize_keys_to_strings(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  @spec ensure_library_id(%{String.t() => any()}) :: %{String.t() => any()}
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

  @spec find_library_id(any()) :: integer() | nil
  defp find_library_id(_), do: nil

  # Ensures required fields have default values when not provided.
  # Added to handle sync operations that may not include MediaInfo-derived fields.
  @spec ensure_required_fields(%{String.t() => any()}) :: %{String.t() => any()}
  defp ensure_required_fields(attrs) do
    attrs
    |> Map.put_new("max_audio_channels", 6)
    |> Map.put_new("atmos", false)
  end

  @spec handle_vmaf_deletion_and_bitrate_preservation(%{String.t() => any()}) :: %{
          String.t() => any()
        }
  defp handle_vmaf_deletion_and_bitrate_preservation(%{"path" => path} = attrs)
       when is_binary(path) do
    case String.trim(path) do
      "" -> attrs
      _valid_path -> process_video_metadata_changes(attrs, path)
    end
  end

  defp handle_vmaf_deletion_and_bitrate_preservation(attrs), do: attrs

  @spec process_video_metadata_changes(%{String.t() => any()}, String.t()) :: %{
          String.t() => any()
        }
  defp process_video_metadata_changes(attrs, path) do
    new_values = VideoValidator.extract_comparison_values(attrs)
    being_marked_encoded = VideoValidator.get_attr_value(attrs, "state") == "encoded"
    existing_video = get_video_metadata_for_comparison(path)

    # Handle VMAF deletion if needed
    maybe_delete_vmafs(existing_video, new_values, being_marked_encoded)

    # Handle bitrate preservation
    handle_bitrate_preservation(attrs, existing_video, new_values, being_marked_encoded, path)
  end

  @spec maybe_delete_vmafs(map() | nil, VideoValidator.comparison_values(), boolean()) :: :ok
  defp maybe_delete_vmafs(existing_video, new_values, being_marked_encoded) do
    if not being_marked_encoded and
         VideoValidator.should_delete_vmafs?(existing_video, new_values) do
      delete_vmafs_for_video(existing_video.id)
      reset_crf_searched_state(existing_video.id)
    end

    :ok
  end

  # When VMAFs are deleted during sync, any crf_searched video must be reset to
  # analyzed — the old VMAF data is invalid and the video needs re-searching.
  defp reset_crf_searched_state(video_id) do
    {count, _} =
      from(v in Video,
        where: v.id == ^video_id and v.state == :crf_searched
      )
      |> Repo.update_all(
        set: [state: :analyzed, chosen_vmaf_id: nil, updated_at: DateTime.utc_now()]
      )

    if count > 0 do
      Logger.info("Reset crf_searched video #{video_id} → analyzed after VMAF deletion")
    end
  end

  @spec handle_bitrate_preservation(
          %{String.t() => any()},
          map() | nil,
          VideoValidator.comparison_values(),
          boolean(),
          String.t()
        ) :: %{String.t() => any()}
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
      |> drop_invalid_mediainfo()
    else
      case existing_video do
        nil -> :ok
        _ -> Logger.debug("Allowing bitrate update for #{path}")
      end

      attrs
    end
  end

  @spec insert_or_update_video(%{String.t() => any()}, map() | nil) ::
          {:ok, Video.t()} | {:error, Ecto.Changeset.t() | any()}
  defp insert_or_update_video(attrs, old_video) do
    conflict_except = determine_conflict_except_fields(attrs)
    on_conflict_query = build_on_conflict_query(attrs, conflict_except)

    attrs
    |> perform_video_upsert(on_conflict_query)
    |> handle_upsert_result(attrs, old_video)
  end

  @spec determine_conflict_except_fields(%{String.t() => any()}) :: [atom()]
  defp determine_conflict_except_fields(attrs) do
    # Always protect state, failed, chosen_vmaf_id, and original_size from sync overwrites.
    # These are set by the encoding pipeline and must never be reset by sync.
    base = [:id, :inserted_at, :state, :failed, :chosen_vmaf_id, :original_size]

    base =
      if preserve_saved_space_size?(attrs) do
        [:size | base]
      else
        base
      end

    base =
      if should_preserve_mediainfo?(attrs) do
        [:mediainfo | base]
      else
        base
      end

    if Map.has_key?(attrs, "bitrate") do
      base
    else
      [:bitrate | base]
    end
  end

  defp should_preserve_mediainfo?(attrs) do
    not Map.has_key?(attrs, "mediainfo") or is_nil(Map.get(attrs, "mediainfo"))
  end

  defp drop_invalid_mediainfo(attrs) do
    case Map.get(attrs, "mediainfo", :missing) do
      :missing -> attrs
      mediainfo when is_map(mediainfo) -> attrs
      _other -> Map.delete(attrs, "mediainfo")
    end
  end

  defp preserve_saved_space_size?(%{"path" => path, "size" => new_size})
       when is_binary(path) and is_integer(new_size) do
    case Repo.one(
           from v in Video,
             where: v.path == ^path and not is_nil(v.original_size),
             select: %{size: v.size}
         ) do
      %{size: ^new_size} -> true
      _ -> false
    end
  end

  defp preserve_saved_space_size?(_), do: false

  @spec build_on_conflict_query(%{String.t() => any()}, [atom()]) ::
          {:replace_all_except, [atom()]} | Ecto.Query.t()
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

  @spec perform_video_upsert(
          %{String.t() => any()},
          {:replace_all_except, [atom()]} | Ecto.Query.t()
        ) :: {:ok, Video.t()} | {:error, Ecto.Changeset.t()}
  defp perform_video_upsert(attrs, on_conflict_query) do
    do_insert(attrs, on_conflict_query)
  end

  @spec perform_single_upsert_in_batch(%{String.t() => any()}, map() | nil) ::
          {:ok, Video.t()} | {:error, Ecto.Changeset.t() | any()}
  defp perform_single_upsert_in_batch(attrs, old_video) do
    conflict_except = determine_conflict_except_fields(attrs)
    on_conflict_query = build_on_conflict_query(attrs, conflict_except)

    case do_insert(attrs, on_conflict_query) do
      {:ok, video} ->
        handle_successful_upsert(video, old_video)

      {:error, %Ecto.Changeset{errors: [updated_at: {"is stale", _}]} = changeset} ->
        handle_stale_update_error(changeset, attrs)

      {:error, changeset} ->
        path = Map.get(attrs, "path", "unknown")
        Logger.error("Failed to upsert video in batch #{path}: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  @spec handle_upsert_result(
          {:ok, Video.t()} | {:error, Ecto.Changeset.t()} | {:error, any()},
          %{String.t() => any()},
          map() | nil
        ) :: {:ok, Video.t()} | {:error, any()}
  defp handle_upsert_result(result, attrs, old_video) do
    case result do
      {:ok, video} ->
        handle_successful_upsert(video, old_video)

      {:error, %Ecto.Changeset{errors: [updated_at: {"is stale", _}]} = changeset} ->
        handle_stale_update_error(changeset, attrs)

      {:error, changeset_or_reason} ->
        Logger.error("Video upsert failed: #{inspect(changeset_or_reason)}")
        {:error, changeset_or_reason}
    end
  end

  # Helper function to handle successful video upserts consistently
  @spec handle_successful_upsert(Video.t(), map() | nil) :: {:ok, Video.t()}
  defp handle_successful_upsert(video, old_video) do
    Logger.debug("Video upserted successfully: #{video.path}")

    # If video is in needs_analysis state, broadcast state transition for queue processing
    if video.state == :needs_analysis do
      VideoStateMachine.broadcast_state_transition(video, :needs_analysis)
    end

    action = if old_video, do: :update, else: :insert

    Reencodarr.Media.broadcast_video_mutation(
      action,
      old_video,
      Reencodarr.Media.fetch_dashboard_video_snapshot_by_id(video.id)
    )

    {:ok, video}
  end

  defp do_insert(attrs, on_conflict_query) do
    %Video{}
    |> Video.changeset(attrs)
    |> Repo.insert(
      on_conflict: on_conflict_query,
      conflict_target: :path,
      stale_error_field: :updated_at,
      returning: true
    )
  end

  defp handle_stale_update_error(changeset, attrs) do
    path = Map.get(attrs, "path")
    Logger.debug("Skipping update for #{path} — dateAdded not newer than updated_at")

    case Repo.get_by(Video, path: path) do
      nil -> {:error, changeset}
      existing_video -> {:ok, existing_video}
    end
  end

  @spec build_conditional_update(%{String.t() => any()}, [atom()], DateTime.t()) :: Ecto.Query.t()
  defp build_conditional_update(attrs, conflict_except, date_added) do
    update_fields =
      attrs
      |> Map.to_list()
      |> Enum.reject(fn {key, _} ->
        string_key = to_string(key)
        Enum.any?(conflict_except, &(to_string(&1) == string_key)) or string_key == "dateAdded"
      end)
      |> Enum.map(fn {key, value} ->
        {:ok, atom_key} = safe_to_existing_atom(key)
        {atom_key, value}
      end)

    from(v in Video,
      update: [set: ^update_fields],
      where: fragment("? > ?", ^date_added, v.updated_at)
    )
  end

  @spec parse_date_added(String.t()) :: {:ok, DateTime.t()} | {:error, atom()}
  defp parse_date_added(date_string) when is_binary(date_string) do
    case DateTime.from_iso8601(date_string) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _} = error -> error
    end
  end

  @spec delete_vmafs_for_video(integer()) :: {integer(), nil}
  defp delete_vmafs_for_video(video_id) do
    from(v in Vmaf, where: v.video_id == ^video_id) |> Repo.delete_all()
  end

  @spec get_video_metadata_for_comparison(String.t()) :: map() | nil
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

  @spec safe_to_existing_atom(binary()) :: {:ok, atom()}
  defp safe_to_existing_atom(key) when is_binary(key) do
    # Only convert if the atom already exists - let it crash if not
    {:ok, String.to_existing_atom(key)}
  end
end
