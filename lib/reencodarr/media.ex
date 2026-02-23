defmodule Reencodarr.Media do
  import Ecto.Query

  import __MODULE__.SharedQueries,
    only: [videos_with_no_chosen_vmafs_query: 0],
    warn: false

  alias Reencodarr.Analyzer.Broadway, as: AnalyzerBroadway
  alias Reencodarr.Core.Parsers

  alias Reencodarr.Media.{
    Library,
    SharedQueries,
    Video,
    VideoFailure,
    VideoQueries,
    VideoStateMachine,
    VideoUpsert,
    Vmaf
  }

  alias Reencodarr.Repo
  require Logger

  @moduledoc "Handles media-related operations and database interactions."

  # --- Video-related functions ---
  def list_videos, do: Repo.all(from v in Video, order_by: [desc: v.updated_at])
  def get_video!(id), do: Repo.get!(Video, id)

  @doc """
  Gets a video by its file path.

  Returns {:ok, video} if found, {:error, :not_found} otherwise.
  """
  @spec get_video_by_path(String.t()) :: {:ok, Video.t()} | {:error, :not_found}
  def get_video_by_path(path) do
    case Repo.one(from v in Video, where: v.path == ^path) do
      nil -> {:error, :not_found}
      video -> {:ok, video}
    end
  end

  def video_exists?(path), do: Repo.exists?(from v in Video, where: v.path == ^path)

  def find_videos_by_path_wildcard(pattern),
    do: Repo.all(from v in Video, where: like(v.path, ^pattern))

  def get_videos_for_crf_search(limit \\ 10) do
    VideoQueries.videos_for_crf_search(limit)
  end

  def count_videos_for_crf_search do
    VideoQueries.count_videos_for_crf_search()
  end

  def get_videos_needing_analysis(limit \\ 10) do
    VideoQueries.videos_needing_analysis(limit)
  end

  def count_videos_needing_analysis do
    VideoQueries.count_videos_needing_analysis()
  end

  # Query for videos ready for encoding (chosen VMAFs with valid videos)
  defp query_videos_ready_for_encoding(limit) do
    VideoQueries.videos_ready_for_encoding(limit)
  end

  def list_videos_by_estimated_percent(limit \\ 10) do
    query_videos_ready_for_encoding(limit)
  end

  def get_next_for_encoding(limit \\ 1) do
    query_videos_ready_for_encoding(limit)
  end

  def encoding_queue_count do
    VideoQueries.encoding_queue_count()
  end

  def upsert_video(attrs) do
    %Video{}
    |> Video.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at, :updated_at]},
      conflict_target: :path
    )
  end

  def batch_upsert_videos(video_attrs_list) do
    VideoUpsert.batch_upsert(video_attrs_list)
  end

  def update_video(%Video{} = video, attrs) do
    video |> Video.changeset(attrs) |> Repo.update()
  end

  def delete_video(%Video{} = video), do: Repo.delete(video)

  def delete_video_with_vmafs(%Video{} = video) do
    delete_videos_by_ids([video.id])
  end

  def change_video(%Video{} = video, attrs \\ %{}) do
    Video.changeset(video, attrs)
  end

  def mark_as_crf_searching(%Video{} = video) do
    VideoStateMachine.mark_as_crf_searching(video)
  end

  def mark_as_encoding(%Video{} = video) do
    VideoStateMachine.mark_as_encoding(video)
  end

  def mark_as_reencoded(%Video{} = video) do
    VideoStateMachine.mark_as_reencoded(video)
  end

  def mark_as_failed(%Video{} = video) do
    VideoStateMachine.mark_as_failed(video)
  end

  def mark_as_analyzed(%Video{} = video) do
    VideoStateMachine.mark_as_analyzed(video)
  end

  def mark_as_crf_searched(%Video{} = video) do
    VideoStateMachine.mark_as_crf_searched(video)
  end

  def mark_as_needs_analysis(%Video{} = video) do
    VideoStateMachine.mark_as_needs_analysis(video)
  end

  def mark_as_encoded(%Video{} = video) do
    VideoStateMachine.mark_as_encoded(video)
  end

  # --- Video Failure Tracking Functions ---

  @doc """
  Records a detailed failure for a video and marks it as failed.

  ## Examples

      iex> record_video_failure(video, "encoding", "process_failure",
      ...>   code: "1", message: "ab-av1 encoding failed")
      {:ok, %VideoFailure{}}
  """
  def record_video_failure(video, stage, category, opts \\ []) do
    with {:ok, failure} <- VideoFailure.record_failure(video, stage, category, opts),
         {:ok, _video} <- mark_as_failed(video) do
      Logger.warning(
        "Recorded #{stage}/#{category} failure for video #{video.id}: #{opts[:message] || "No message"}"
      )

      {:ok, failure}
    else
      {:error, %Ecto.Changeset{errors: [video_id: {"does not exist", _}]}} ->
        # Video was deleted during test cleanup - this is expected in test environment
        Logger.debug("Video #{video.id} no longer exists, skipping failure recording")
        {:ok, video}

      error ->
        Logger.error("Failed to record video failure: #{inspect(error)}")
        error
    end
  end

  @doc """
  Gets unresolved failures for a video.
  """
  def get_video_failures(video_id), do: VideoFailure.get_unresolved_failures_for_video(video_id)

  @doc """
  Resolves all failures for a video (typically when re-processing succeeds).
  """
  def resolve_video_failures(video_id) do
    now = DateTime.utc_now()

    from(f in VideoFailure,
      where: f.video_id == ^video_id and f.resolved == false,
      update: [set: [resolved: true, resolved_at: ^now]]
    )
    |> Repo.update_all([])
  end

  @doc """
  Gets failure statistics for monitoring and investigation.
  """
  def get_failure_statistics(opts \\ []), do: VideoFailure.get_failure_statistics(opts)

  @doc """
  Gets common failure patterns for investigation.
  """
  def get_common_failure_patterns(limit \\ 10),
    do: VideoFailure.get_common_failure_patterns(limit)

  @doc """
  Counts videos that would generate invalid audio encoding arguments (b:a=0k, ac=0).

  Tests each video by calling Rules.build_args/2 and checking if it produces invalid
  audio encoding arguments like "--enc b:a=0k" or "--enc ac=0". Useful for monitoring
  and deciding whether to run reset_videos_with_invalid_audio_args/0.

  ## Examples
      iex> Media.count_videos_with_invalid_audio_args()
      %{videos_tested: 1250, videos_with_invalid_args: 42}
  """
  @spec count_videos_with_invalid_audio_args() :: %{
          videos_tested: integer(),
          videos_with_invalid_args: integer()
        }
  def count_videos_with_invalid_audio_args do
    # Get all videos that haven't been processed yet
    videos_to_test =
      from(v in Video,
        where: v.state not in [:encoded, :failed],
        select: v
      )
      |> Repo.all()

    videos_tested_count = length(videos_to_test)

    # Test each video to see if it produces invalid audio args
    videos_with_invalid_args_count =
      videos_to_test
      |> Enum.count(&produces_invalid_audio_args?/1)

    %{
      videos_tested: videos_tested_count,
      videos_with_invalid_args: videos_with_invalid_args_count
    }
  end

  @doc """
  One-liner to reset videos that would generate invalid audio encoding arguments (b:a=0k, ac=0).

  Tests each video by calling Rules.build_args/2 and checking if it produces invalid
  audio encoding arguments like "--enc b:a=0k" or "--enc ac=0". Resets analysis
  fields and deletes VMAFs for videos that would generate these invalid arguments.

  ## Examples
      iex> Media.reset_videos_with_invalid_audio_args()
      %{videos_tested: 1250, videos_reset: 42, vmafs_deleted: 156}
  """
  @spec reset_videos_with_invalid_audio_args() :: %{
          videos_tested: integer(),
          videos_reset: integer(),
          vmafs_deleted: integer()
        }
  def reset_videos_with_invalid_audio_args do
    # Get all videos that haven't been processed yet
    videos_to_test =
      from(v in Video,
        where: v.state not in [:encoded, :failed],
        select: v
      )
      |> Repo.all()

    videos_tested_count = length(videos_to_test)

    # Test each video to see if it produces invalid audio args
    problematic_video_ids =
      videos_to_test
      |> Enum.filter(&produces_invalid_audio_args?/1)
      |> Enum.map(& &1.id)

    reset_problematic_videos(problematic_video_ids, videos_tested_count)
  end

  # Helper function to reset problematic videos
  defp reset_problematic_videos([], videos_tested_count) do
    %{videos_tested: videos_tested_count, videos_reset: 0, vmafs_deleted: 0}
  end

  defp reset_problematic_videos(problematic_video_ids, videos_tested_count) do
    videos_reset_count = length(problematic_video_ids)

    Repo.transaction(fn ->
      # Delete VMAFs for these videos (they were generated with bad audio data)
      {vmafs_deleted_count, _} =
        from(v in Vmaf, where: v.video_id in ^problematic_video_ids)
        |> Repo.delete_all()

      # Reset analysis fields to force re-analysis
      from(v in Video, where: v.id in ^problematic_video_ids)
      |> Repo.update_all(
        set: [
          bitrate: nil,
          video_codecs: nil,
          audio_codecs: nil,
          max_audio_channels: nil,
          atmos: nil,
          hdr: nil,
          width: nil,
          height: nil,
          frame_rate: nil,
          duration: nil,
          updated_at: DateTime.utc_now()
        ]
      )

      %{
        videos_tested: videos_tested_count,
        videos_reset: videos_reset_count,
        vmafs_deleted: vmafs_deleted_count
      }
    end)
    |> case do
      {:ok, result} ->
        result

      {:error, _reason} ->
        %{videos_tested: videos_tested_count, videos_reset: 0, vmafs_deleted: 0}
    end
  end

  # Helper function to test if a video would produce invalid audio encoding arguments
  defp produces_invalid_audio_args?(video) do
    # Generate encoding arguments using the Rules module
    args = Reencodarr.Rules.build_args(video, :encode)

    # Look for invalid audio encoding arguments
    opus_args =
      args
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.filter(fn
        [flag, value] when flag == "--enc" ->
          String.contains?(value, "b:a=") or String.contains?(value, "ac=")

        _ ->
          false
      end)

    # Check if any of the audio args are invalid (0 bitrate or 0 channels)
    Enum.any?(opus_args, fn
      ["--enc", value] ->
        String.contains?(value, "b:a=0k") or String.contains?(value, "ac=0")

      _ ->
        false
    end)
  end

  @doc """
  One-liner to reset videos with invalid audio metadata that would cause 0 bitrate/channels.

  Finds videos where max_audio_channels is nil/0 OR audio_codecs is nil/empty,
  resets their analysis fields, and deletes their VMAFs since they're based on bad data.

  ## Examples
      iex> Media.reset_videos_with_invalid_audio_metadata()
      %{videos_reset: 42, vmafs_deleted: 156}
  """
  @spec reset_videos_with_invalid_audio_metadata() :: %{
          videos_reset: integer(),
          vmafs_deleted: integer()
        }
  def reset_videos_with_invalid_audio_metadata do
    Repo.transaction(fn ->
      # Find videos with problematic audio metadata that would cause Rules.audio/1 to return []
      # This happens when max_audio_channels is nil/0 OR audio_codecs is nil/empty
      # SQLite: audio_codecs is stored as JSON, check if empty with json_array_length
      problematic_video_ids =
        from(v in Video,
          where:
            v.state not in [:encoded, :failed] and
              v.atmos != true and
              (is_nil(v.max_audio_channels) or v.max_audio_channels == 0 or
                 is_nil(v.audio_codecs) or
                 fragment("json_array_length(?) = 0", v.audio_codecs)),
          select: v.id
        )
        |> Repo.all()

      videos_reset_count = length(problematic_video_ids)

      # Delete VMAFs for these videos (they were generated with bad audio data)
      {vmafs_deleted_count, _} =
        from(v in Vmaf, where: v.video_id in ^problematic_video_ids)
        |> Repo.delete_all()

      # Reset analysis fields to force re-analysis
      from(v in Video, where: v.id in ^problematic_video_ids)
      |> Repo.update_all(
        set: [
          bitrate: nil,
          video_codecs: nil,
          audio_codecs: nil,
          max_audio_channels: nil,
          atmos: nil,
          hdr: nil,
          width: nil,
          height: nil,
          frame_rate: nil,
          duration: nil,
          updated_at: DateTime.utc_now()
        ]
      )

      %{
        videos_reset: videos_reset_count,
        vmafs_deleted: vmafs_deleted_count
      }
    end)
    |> case do
      {:ok, result} -> result
      {:error, _reason} -> %{videos_reset: 0, vmafs_deleted: 0}
    end
  end

  @doc """
  Convenience function to reset all failed videos and clear their failure entries.

  This is useful for mass retry scenarios after fixing configuration issues
  or updating encoding logic. Clears the `failed` flag on videos, removes all
  associated VideoFailure records, and deletes VMAFs for failed videos since
  they were likely generated with incorrect data.

  Returns a summary of the operation.
  """
  @spec reset_all_failures() :: %{
          videos_reset: integer(),
          failures_deleted: integer(),
          vmafs_deleted: integer()
        }
  def reset_all_failures do
    Repo.transaction(fn ->
      # First, get IDs and counts of videos that will be reset
      failed_video_ids =
        from(v in Video, where: v.state == :failed, select: v.id)
        |> Repo.all()

      videos_to_reset_count = length(failed_video_ids)

      # Get count of failures that will be deleted
      failures_to_delete_count =
        from(f in VideoFailure, where: is_nil(f.resolved_at), select: count(f.id))
        |> Repo.one()

      # Delete VMAFs for failed videos (they were likely generated with bad data)
      {vmafs_deleted_count, _} =
        from(v in Vmaf, where: v.video_id in ^failed_video_ids)
        |> Repo.delete_all()

      # Reset all failed videos back to needs_analysis
      from(v in Video, where: v.state == :failed)
      |> Repo.update_all(set: [state: :needs_analysis, updated_at: DateTime.utc_now()])

      # Delete all unresolved failures
      from(f in VideoFailure, where: is_nil(f.resolved_at))
      |> Repo.delete_all()

      %{
        videos_reset: videos_to_reset_count,
        failures_deleted: failures_to_delete_count,
        vmafs_deleted: vmafs_deleted_count
      }
    end)
    |> case do
      {:ok, result} -> result
      {:error, _reason} -> %{videos_reset: 0, failures_deleted: 0, vmafs_deleted: 0}
    end
  end

  # Consolidated shared logic for video deletion
  defp delete_videos_by_ids(video_ids) do
    Repo.transaction(fn ->
      from(v in Vmaf, where: v.video_id in ^video_ids) |> Repo.delete_all()
      from(v in Video, where: v.id in ^video_ids) |> Repo.delete_all()
    end)
  end

  def delete_videos_with_path(path) do
    case_insensitive_like_condition = SharedQueries.case_insensitive_like(:path, path)

    video_ids =
      from(v in Video, where: ^case_insensitive_like_condition, select: v.id) |> Repo.all()

    delete_videos_by_ids(video_ids)
  end

  def delete_videos_with_nonexistent_paths do
    Logger.info("Starting cleanup of videos with nonexistent paths...")

    deleted_count = delete_missing_files_batched(0, 0)

    Logger.info("Cleanup complete: deleted #{deleted_count} videos with nonexistent paths")
    {:ok, deleted_count}
  end

  defp delete_missing_files_batched(last_id, total_deleted) do
    batch =
      from(v in Video,
        where: v.id > ^last_id,
        order_by: [asc: v.id],
        limit: 500,
        select: %{id: v.id, path: v.path}
      )
      |> Repo.all()

    case batch do
      [] ->
        total_deleted

      videos ->
        missing_ids = find_missing_file_ids(videos)
        new_total = delete_missing_batch(missing_ids, total_deleted, List.last(videos).id)
        delete_missing_files_batched(List.last(videos).id, new_total)
    end
  end

  defp find_missing_file_ids(videos) do
    videos
    |> Task.async_stream(
      fn video -> {video.id, file_missing?(video)} end,
      max_concurrency: 20,
      timeout: 10_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, {id, true}} -> [id]
      _ -> []
    end)
  end

  defp delete_missing_batch([], total_deleted, _last_id), do: total_deleted

  defp delete_missing_batch(missing_ids, total_deleted, last_id) do
    Repo.transaction(fn ->
      from(v in Vmaf, where: v.video_id in ^missing_ids) |> Repo.delete_all()
      {count, _} = from(v in Video, where: v.id in ^missing_ids) |> Repo.delete_all()
      count
    end)
    |> case do
      {:ok, count} ->
        Logger.info(
          "Deleted #{count} missing videos (#{total_deleted + count} total, last_id: #{last_id})"
        )

        total_deleted + count

      {:error, reason} ->
        Logger.error("Failed to delete batch: #{inspect(reason)}")
        total_deleted
    end
  end

  defp file_missing?(%{path: path}), do: not File.exists?(path)

  # --- Library-related functions ---
  def list_libraries do
    Repo.all(from(l in Library))
  end

  def get_library!(id) do
    Repo.get!(Library, id)
  end

  def create_library(attrs \\ %{}) do
    %Library{} |> Library.changeset(attrs) |> Repo.insert()
  end

  def update_library(%Library{} = l, attrs) do
    l |> Library.changeset(attrs) |> Repo.update()
  end

  def delete_library(%Library{} = l), do: Repo.delete(l)

  def change_library(%Library{} = l, attrs \\ %{}) do
    Library.changeset(l, attrs)
  end

  # --- Vmaf-related functions ---
  def list_vmafs, do: Repo.all(Vmaf)
  def get_vmaf!(id), do: Repo.get!(Vmaf, id) |> Repo.preload(:video)

  def create_vmaf(attrs \\ %{}) do
    %Vmaf{} |> Vmaf.changeset(attrs) |> Repo.insert()
  end

  def upsert_vmaf(attrs) do
    video_id = Map.get(attrs, "video_id") || Map.get(attrs, :video_id)

    if is_integer(video_id) or is_binary(video_id) do
      do_upsert_vmaf(attrs, video_id)
    else
      Logger.error("Attempted to upsert VMAF with invalid video_id type: #{inspect(attrs)}")
      {:error, :invalid_video_id}
    end
  end

  defp do_upsert_vmaf(attrs, video_id) do
    case get_video(video_id) do
      %Video{} = video ->
        attrs_with_savings = maybe_calculate_savings(attrs, video)

        result =
          %Vmaf{}
          |> Vmaf.changeset(attrs_with_savings)
          |> Repo.insert(
            on_conflict: {:replace_all_except, [:id, :video_id, :inserted_at]},
            conflict_target: [:crf, :video_id]
          )

        case result do
          {:ok, vmaf} -> handle_chosen_vmaf(vmaf, video)
          {:error, _error} -> :ok
        end

        result

      nil ->
        Logger.error("Attempted to upsert VMAF with missing video_id: #{inspect(attrs)}")
        {:error, :invalid_video_id}
    end
  end

  # Helper function to handle chosen VMAF updates
  defp handle_chosen_vmaf(%{chosen: true}, %Video{} = video) do
    mark_as_crf_searched(video)
  end

  defp handle_chosen_vmaf(_vmaf, _video), do: :ok

  # Calculate savings if not already provided and we have the necessary data
  defp maybe_calculate_savings(attrs, %Video{} = video) do
    case {Map.get(attrs, "savings"), Map.get(attrs, "percent")} do
      {nil, percent} when is_number(percent) or is_binary(percent) ->
        case video do
          %Video{size: size} when is_integer(size) and size > 0 ->
            savings = calculate_vmaf_savings(percent, size)
            Map.put(attrs, "savings", savings)

          _ ->
            attrs
        end

      _ ->
        attrs
    end
  end

  # Calculate estimated space savings in bytes based on percent and video size
  defp calculate_vmaf_savings(percent, video_size) when is_binary(percent) do
    case Parsers.parse_float_exact(percent) do
      {:ok, percent_float} -> calculate_vmaf_savings(percent_float, video_size)
      {:error, _} -> nil
    end
  end

  defp calculate_vmaf_savings(percent, video_size)
       when is_number(percent) and is_number(video_size) and
              percent > 0 and percent <= 100 do
    # Savings = (100 - percent) / 100 * original_size
    round((100 - percent) / 100 * video_size)
  end

  defp calculate_vmaf_savings(_, _), do: nil

  def update_vmaf(%Vmaf{} = vmaf, attrs) do
    vmaf |> Vmaf.changeset(attrs) |> Repo.update()
  end

  def delete_vmaf(%Vmaf{} = vmaf), do: Repo.delete(vmaf)

  @doc """
  Deletes all VMAFs for a given video ID.

  ## Parameters
    - `video_id`: integer video ID

  ## Returns
    - `{count, nil}` where count is the number of deleted VMAFs

  ## Examples
      iex> Media.delete_vmafs_for_video(123)
      {3, nil}
  """
  def delete_vmafs_for_video(video_id) when is_integer(video_id) do
    from(v in Vmaf, where: v.video_id == ^video_id)
    |> Repo.delete_all()
  end

  @doc """
  Forces complete re-analysis of a video by resetting all analysis data and manually queuing it.

  This function:
  1. Deletes all VMAFs for the video
  2. Resets video analysis fields (bitrate, etc.)
  3. Manually adds the video to the analyzer queue
  4. Returns the video path for verification

  ## Parameters
    - `video_id`: integer video ID

  ## Returns
    - `{:ok, video_path}` on success
    - `{:error, reason}` if video not found

  ## Examples
      iex> Media.force_reanalyze_video(9008028)
      {:ok, "/path/to/video.mkv"}
  """
  def force_reanalyze_video(video_id) when is_integer(video_id) do
    case get_video(video_id) do
      nil ->
        {:error, "Video #{video_id} not found"}

      video ->
        Repo.transaction(fn ->
          # 1. Delete all VMAFs
          delete_vmafs_for_video(video_id)

          # 2. Reset analysis fields to force re-analysis
          update_video(video, %{
            bitrate: nil,
            video_codecs: nil,
            audio_codecs: nil,
            max_audio_channels: nil,
            atmos: nil,
            hdr: nil,
            width: nil,
            height: nil,
            frame_rate: nil,
            duration: nil
          })

          # 3. Manually trigger analysis using Broadway dispatch
          AnalyzerBroadway.dispatch_available()

          video.path
        end)
        |> case do
          {:ok, path} -> {:ok, path}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def change_vmaf(%Vmaf{} = vmaf, attrs \\ %{}) do
    Vmaf.changeset(vmaf, attrs)
  end

  def chosen_vmaf_exists?(%{id: id}),
    do: Repo.exists?(from v in Vmaf, where: v.video_id == ^id and v.chosen == true)

  @doc """
  Checks if any VMAF records exist for a video (regardless of chosen status).
  Used to validate that CRF search actually produced results.
  """
  def vmaf_records_exist?(%{id: id}),
    do: Repo.exists?(from v in Vmaf, where: v.video_id == ^id)

  # Consolidated shared logic for chosen VMAF queries
  defp query_chosen_vmafs do
    from v in Vmaf,
      join: vid in assoc(v, :video),
      where: v.chosen == true and vid.state == :crf_searched,
      select: %{v | video: vid},
      order_by: [asc: v.percent, asc: v.time]
  end

  # Function to list all chosen VMAFs
  def list_chosen_vmafs do
    Repo.all(query_chosen_vmafs())
  end

  # Function to get the chosen VMAF for a specific video
  def get_chosen_vmaf_for_video(%Video{id: video_id}) do
    Repo.one(
      from v in Vmaf,
        join: vid in assoc(v, :video),
        where: v.chosen == true and v.video_id == ^video_id and vid.state == :crf_searched,
        select: %{v | video: vid},
        order_by: [asc: v.percent, asc: v.time]
    )
  end

  # --- Queue helpers ---

  def get_next_for_encoding_by_time do
    result =
      Repo.one(
        from v in Vmaf,
          join: vid in assoc(v, :video),
          # Ensure video is properly analyzed before encoding
          where: v.chosen == true and vid.state == :crf_searched,
          order_by: [fragment("? DESC NULLS LAST", v.savings), asc: v.time],
          limit: 1,
          select: %{v | video: vid}
      )

    if result, do: [result], else: []
  end

  def mark_vmaf_as_chosen(video_id, crf) do
    crf_float = parse_crf(crf)

    Repo.transaction(fn ->
      from(v in Vmaf, where: v.video_id == ^video_id, update: [set: [chosen: false]])
      |> Repo.update_all([])

      from(v in Vmaf,
        where: v.video_id == ^video_id and v.crf == ^crf_float,
        update: [set: [chosen: true]]
      )
      |> Repo.update_all([])
    end)
  end

  defp parse_crf(crf) when is_number(crf), do: crf

  defp parse_crf(crf) when is_binary(crf) do
    case Parsers.parse_float_exact(crf) do
      {:ok, float} -> float
      {:error, _} -> 0.0
    end
  end

  def list_videos_awaiting_crf_search do
    from(v in Video,
      left_join: vmafs in assoc(v, :vmafs),
      where: is_nil(vmafs.id) and v.state == :analyzed,
      select: v
    )
    |> Repo.all()
  end

  def get_video(id) do
    Repo.get(Video, id)
  end

  def get_video_by_service_id(service_id, service_type)
      when is_binary(service_id) or is_integer(service_id) do
    case Repo.one(
           from v in Video, where: v.service_id == ^service_id and v.service_type == ^service_type
         ) do
      nil -> {:error, :not_found}
      video -> {:ok, video}
    end
  end

  def get_video_by_service_id(nil, _service_type), do: {:error, :invalid_service_id}

  def count_videos do
    Repo.aggregate(Video, :count, :id)
  end

  def get_videos_in_library(library_id) do
    Repo.all(from v in Video, where: v.library_id == ^library_id)
  end

  def get_vmafs_for_video(video_id) do
    Repo.all(from v in Vmaf, where: v.video_id == ^video_id)
  end

  def delete_unchosen_vmafs do
    Repo.transaction(fn ->
      # Get video_ids that have vmafs but none are chosen
      video_ids_with_no_chosen_vmafs =
        videos_with_no_chosen_vmafs_query()
        |> Repo.all()

      # Delete all vmafs for those video_ids
      from(v in Vmaf, where: v.video_id in ^video_ids_with_no_chosen_vmafs)
      |> Repo.delete_all()
    end)
  end

  # --- Bulk operations ---

  @doc """
  Reset all videos for reanalysis by clearing their bitrate.
  This is much more efficient than calling Analyzer.reanalyze_video/1 for each video.
  Videos will be automatically picked up by the analyzer when there's demand.
  VMAFs will be deleted automatically when videos are re-analyzed and their properties change.
  """
  def reset_all_videos_for_reanalysis do
    from(v in Video,
      where: v.state not in [:encoded, :failed],
      update: [set: [bitrate: nil]]
    )
    |> Repo.update_all([])
  end

  @doc """
  Reset videos for reanalysis in batches to avoid overwhelming the Broadway queue.
  VMAFs will be deleted automatically when videos are re-analyzed and their properties change.
  """
  def reset_videos_for_reanalysis_batched(batch_size \\ 1000) do
    total =
      Stream.unfold(0, fn _offset ->
        batch_ids =
          from(v in Video,
            where: v.state not in [:encoded, :failed] and not is_nil(v.bitrate),
            limit: ^batch_size,
            select: v.id
          )
          |> Repo.all()

        if batch_ids != [] do
          {count, _} =
            from(v in Video, where: v.id in ^batch_ids, update: [set: [bitrate: nil]])
            |> Repo.update_all([])

          Logger.info("Reset batch of #{count} videos for reanalysis")
          Process.sleep(100)
          {count, 0}
        else
          nil
        end
      end)
      |> Enum.sum()

    Logger.info("Completed resetting #{total} videos for reanalysis")
    total
  end

  @doc """
  Reset all failed videos to not failed in a single bulk operation.
  """
  def reset_failed_videos do
    from(v in Video,
      where: v.state == :failed,
      update: [set: [state: :needs_analysis]]
    )
    |> Repo.update_all([])
  end

  @doc """
  Reset all videos to needs_analysis state for complete reprocessing.
  This will force all videos to go through analysis again.
  """
  def reset_all_videos_to_needs_analysis do
    from(v in Video,
      update: [set: [state: :needs_analysis, bitrate: nil]]
    )
    |> Repo.update_all([])
  end

  @doc """
  Force trigger analysis of a specific video for debugging.
  """
  def debug_force_analyze_video(video_path) when is_binary(video_path) do
    case get_video_by_path(video_path) do
      {:ok, %{path: _path, service_id: _service_id, service_type: _service_type} = video} ->
        Logger.info("🐛 Force analyzing video: #{video_path}")

        # Trigger Broadway dispatch instead of old compatibility API
        result1 = AnalyzerBroadway.dispatch_available()

        # Delete all VMAFs and reset analysis fields to force re-analysis
        delete_vmafs_for_video(video.id)

        update_video(video, %{
          bitrate: nil,
          duration: nil,
          frame_rate: nil,
          video_codecs: nil,
          audio_codecs: nil,
          max_audio_channels: nil,
          resolution: nil,
          file_size: nil
        })

        # Use state machine for state transition
        mark_as_needs_analysis(video)

        %{
          video: video,
          dispatch_result: result1,
          broadway_running: AnalyzerBroadway.running?()
        }

      {:error, :not_found} ->
        {:error, "Video not found at path: #{video_path}"}
    end
  end

  @doc """
  Get dashboard statistics with safe timeout handling.

  Runs two single-table queries (videos + vmafs) and merges the results,
  avoiding the slow LEFT JOIN that caused dirty-NIF / DBConnection timeouts.
  Returns merged stats or defaults on timeout/error.
  """
  @spec get_dashboard_stats(integer()) :: map()
  def get_dashboard_stats(timeout \\ 15_000) do
    video_task =
      Task.async(fn -> Repo.one(SharedQueries.video_stats_query(), timeout: timeout) end)

    vmaf_task = Task.async(fn -> Repo.one(SharedQueries.vmaf_stats_query(), timeout: timeout) end)

    video_stats = Task.await(video_task, timeout + 500)
    vmaf_stats = Task.await(vmaf_task, timeout + 500)

    Map.merge(video_stats || get_default_video_stats(), vmaf_stats || get_default_vmaf_stats())
  rescue
    DBConnection.ConnectionError -> get_default_stats()
  catch
    :exit, {:timeout, _} -> get_default_stats()
    :exit, {%DBConnection.ConnectionError{}, _} -> get_default_stats()
  end

  defp get_default_video_stats do
    %{
      total_videos: 0,
      total_size_gb: 0.0,
      needs_analysis: 0,
      analyzed: 0,
      crf_searching: 0,
      crf_searched: 0,
      encoding: 0,
      encoded: 0,
      failed: 0,
      avg_duration_minutes: 0.0,
      most_recent_video_update: nil,
      most_recent_inserted_video: nil
    }
  end

  defp get_default_vmaf_stats do
    %{
      total_vmafs: 0,
      chosen_vmafs: 0,
      total_savings_gb: 0.0
    }
  end

  defp get_default_stats do
    Map.merge(get_default_video_stats(), get_default_vmaf_stats())
  end

  @doc """
  Debug function to show how the encoding queue alternates between libraries.
  """
  def debug_encoding_queue_by_library(limit \\ 10) do
    videos = query_videos_ready_for_encoding(limit)

    videos
    |> Enum.with_index()
    |> Enum.map(fn {vmaf, index} ->
      %{
        position: index + 1,
        library_id: vmaf.video.library_id,
        video_path: vmaf.video.path,
        percent: vmaf.percent,
        savings: vmaf.savings
      }
    end)
  end

  @doc """
  Diagnostic function to test inserting a video path and report exactly what happened.

  This function attempts to create or upsert a video with minimal required data and
  provides detailed feedback about the operation including any validation errors,
  constraint violations, or success messages.

  ## Examples

      iex> Reencodarr.Media.test_insert_path("/path/to/test/video.mkv")
      %{
        success: true,
        operation: "insert",
        video_id: 123,
        messages: ["Successfully inserted new video"],
        path: "/path/to/test/video.mkv",
        library_id: 1,
        errors: []
      }

      iex> Reencodarr.Media.test_insert_path("/path/to/existing/video.mkv")
      %{
        success: true,
        operation: "upsert",
        video_id: 124,
        messages: ["Video already existed, updated successfully"],
        path: "/path/to/existing/video.mkv",
        library_id: 1,
        errors: []
      }
  """
  @spec test_insert_path(String.t(), map()) :: %{
          success: boolean(),
          operation: String.t(),
          video_id: integer() | nil,
          messages: [String.t()],
          path: String.t(),
          library_id: integer() | nil,
          errors: [String.t()],
          file_exists: boolean(),
          had_existing_video: boolean()
        }
  def test_insert_path(path, additional_attrs \\ %{}) when is_binary(path) do
    Logger.info("🧪 Testing path insertion: #{path}")

    # Gather initial diagnostics
    diagnostics = gather_path_diagnostics(path, additional_attrs)

    # Attempt the upsert operation
    result = attempt_video_upsert(diagnostics)

    # Build final result with all diagnostics
    build_final_result(result, diagnostics)
  end

  defp gather_path_diagnostics(path, additional_attrs) do
    file_exists = File.exists?(path)
    existing_video = get_video_by_path(path)

    # Find library for this path - same logic as in VideoUpsert
    library_id =
      Repo.one(
        from l in Library,
          where: fragment("? LIKE ? || '%'", ^path, l.path),
          order_by: [desc: fragment("LENGTH(?)", l.path)],
          limit: 1,
          select: l.id
      )

    attrs = build_base_attrs(path, library_id) |> Map.merge(additional_attrs)

    {messages, errors} = build_diagnostic_messages(file_exists, existing_video, library_id, path)

    %{
      path: path,
      file_exists: file_exists,
      existing_video: existing_video,
      library_id: library_id,
      attrs: attrs,
      messages: messages,
      errors: errors
    }
  end

  defp build_base_attrs(path, library_id) do
    %{
      "path" => path,
      "library_id" => library_id,
      "service_type" => "sonarr",
      "service_id" => "test_#{System.system_time(:second)}",
      "size" => 1_000_000,
      "duration" => 3600.0,
      "video_codecs" => ["H.264"],
      "audio_codecs" => ["AAC"],
      "state" => "needs_analysis",
      "failed" => false
    }
  end

  defp build_diagnostic_messages(file_exists, existing_video, library_id, path) do
    messages = []
    errors = []

    {messages, errors} = add_file_existence_messages(file_exists, path, messages, errors)
    messages = add_existing_video_messages(existing_video, messages)
    {messages, errors} = add_library_messages(library_id, path, messages, errors)

    {messages, errors}
  end

  defp add_file_existence_messages(true, _path, messages, errors) do
    {["File exists on filesystem" | messages], errors}
  end

  defp add_file_existence_messages(false, path, messages, errors) do
    {["File does not exist on filesystem" | messages],
     ["File does not exist on filesystem: #{path}" | errors]}
  end

  defp add_existing_video_messages(existing_video, messages) do
    case existing_video do
      {:error, :not_found} -> ["No existing video found in database" | messages]
      {:ok, %Video{id: id}} -> ["Found existing video with ID: #{id}" | messages]
    end
  end

  defp add_library_messages(library_id, _path, messages, errors) do
    case library_id do
      nil ->
        {["No matching library found for path" | messages],
         ["No matching library found for path" | errors]}

      lib_id ->
        {["Found library ID: #{lib_id}" | messages], errors}
    end
  end

  defp attempt_video_upsert(diagnostics) do
    case upsert_video(diagnostics.attrs) do
      {:ok, video} ->
        operation = if match?({:ok, _}, diagnostics.existing_video), do: "upsert", else: "insert"

        %{
          success: true,
          operation: operation,
          video_id: video.id,
          messages: [
            "Successfully #{operation}ed video with ID: #{video.id}" | diagnostics.messages
          ],
          errors: diagnostics.errors
        }

      {:error, %Ecto.Changeset{} = changeset} ->
        changeset_errors =
          changeset.errors
          |> Enum.map(fn {field, {message, _}} -> "#{field}: #{message}" end)

        %{
          success: false,
          operation: "failed",
          video_id: nil,
          messages: ["Changeset validation failed" | diagnostics.messages],
          errors: changeset_errors ++ diagnostics.errors
        }

      {:error, reason} ->
        %{
          success: false,
          operation: "failed",
          video_id: nil,
          messages: ["Operation failed with error" | diagnostics.messages],
          errors: ["Error: #{inspect(reason)}" | diagnostics.errors]
        }
    end
  end

  defp build_final_result(result, diagnostics) do
    final_result =
      result
      |> Map.put(:path, diagnostics.path)
      |> Map.put(:library_id, diagnostics.library_id)
      |> Map.put(:file_exists, diagnostics.file_exists)
      |> Map.put(:had_existing_video, match?({:ok, %Video{}}, diagnostics.existing_video))
      |> Map.put(:messages, Enum.reverse(result.messages))
      |> Map.put(:errors, Enum.reverse(result.errors))

    Logger.info("🧪 Test result: #{if result.success, do: "SUCCESS", else: "FAILED"}")

    log_test_result_details(result)

    final_result
  end

  # Helper function to log test result details
  defp log_test_result_details(%{success: true, video_id: video_id, operation: operation}) do
    Logger.info("   Video ID: #{video_id}, Operation: #{operation}")
  end

  defp log_test_result_details(%{success: false, errors: errors}) do
    Logger.warning("   Errors: #{Enum.join(errors, ", ")}")
  end
end
