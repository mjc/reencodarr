defmodule Reencodarr.Media.BulkOperations do
  @moduledoc """
  Handles bulk operations for the Media context.

  Extracted from the main Media module to provide specialized functionality
  for batch processing, cleanup operations, and mass data manipulation.
  """

  import Ecto.Query
  import Reencodarr.Media.SharedQueries, only: [videos_with_no_chosen_vmafs_query: 0]
  alias Reencodarr.Media.{Video, VideoFailure, Vmaf}
  alias Reencodarr.Repo
  require Logger

  @doc """
  Counts videos that would generate invalid audio encoding arguments (b:a=0k, ac=0).

  Tests each video by calling Rules.build_args/2 and checking if it produces invalid
  audio encoding arguments like "--enc b:a=0k" or "--enc ac=0". Useful for monitoring
  and deciding whether to run reset_videos_with_invalid_audio_args/0.

  ## Examples
      iex> BulkOperations.count_videos_with_invalid_audio_args()
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
      iex> BulkOperations.reset_videos_with_invalid_audio_args()
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

    videos_reset_count = length(problematic_video_ids)

    if videos_reset_count > 0 do
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
    else
      %{
        videos_tested: videos_tested_count,
        videos_reset: 0,
        vmafs_deleted: 0
      }
    end
  end

  @doc """
  One-liner to reset videos with invalid audio metadata that would cause 0 bitrate/channels.

  Finds videos where max_audio_channels is nil/0 OR audio_codecs is nil/empty,
  resets their analysis fields, and deletes their VMAFs since they're based on bad data.

  ## Examples
      iex> BulkOperations.reset_videos_with_invalid_audio_metadata()
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
      problematic_video_ids =
        from(v in Video,
          where:
            v.state not in [:encoded, :failed] and
              v.atmos != true and
              (is_nil(v.max_audio_channels) or v.max_audio_channels == 0 or
                 is_nil(v.audio_codecs) or fragment("array_length(?, 1) IS NULL", v.audio_codecs)),
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

  @doc """
  Reset all videos for reanalysis by clearing their bitrate.
  This is much more efficient than calling Analyzer.reanalyze_video/1 for each video.
  Videos will be automatically picked up by the analyzer when there's demand.
  VMAFs will be deleted automatically when videos are re-analyzed and their properties change.
  """
  @spec reset_all_videos_for_reanalysis() :: {integer(), nil}
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
  @spec reset_videos_for_reanalysis_batched(integer()) :: :ok
  def reset_videos_for_reanalysis_batched(batch_size \\ 1000) do
    videos_to_reset =
      from(v in Video,
        where: v.state not in [:encoded, :failed],
        select: %{id: v.id}
      )
      |> Repo.all()

    total_videos = length(videos_to_reset)
    Logger.info("Resetting #{total_videos} videos for reanalysis in batches of #{batch_size}")

    videos_to_reset
    |> Enum.chunk_every(batch_size)
    |> Enum.with_index()
    |> Enum.each(fn {batch, index} ->
      Logger.info("Processing batch #{index + 1}/#{div(total_videos, batch_size) + 1}")

      # Reset bitrate for this batch (set to NULL so analyzer picks them up)
      video_ids = Enum.map(batch, & &1.id)

      from(v in Video, where: v.id in ^video_ids, update: [set: [bitrate: nil]])
      |> Repo.update_all([])

      # Small delay to prevent overwhelming the system
      Process.sleep(100)
    end)

    Logger.info("Completed resetting videos for reanalysis")
  end

  @doc """
  Reset all failed videos to not failed in a single bulk operation.
  """
  @spec reset_failed_videos() :: {integer(), nil}
  def reset_failed_videos do
    from(v in Video,
      where: v.state == :failed,
      update: [set: [state: :needs_analysis]]
    )
    |> Repo.update_all([])
  end

  @doc """
  Deletes all unchosen VMAFs to clean up the database.
  """
  @spec delete_unchosen_vmafs() :: {integer(), nil}
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

  @doc """
  Deletes videos with paths matching the given pattern.
  """
  @spec delete_videos_with_path(String.t()) :: {integer(), nil}
  def delete_videos_with_path(path) do
    video_ids = from(v in Video, where: ilike(v.path, ^path), select: v.id) |> Repo.all()
    delete_videos_by_ids(video_ids)
  end

  @doc """
  Deletes videos that reference non-existent file paths.
  """
  @spec delete_videos_with_nonexistent_paths() :: {integer(), nil}
  def delete_videos_with_nonexistent_paths do
    video_ids = get_video_ids_with_missing_files()
    delete_videos_by_ids(video_ids)
  end

  # === Private Helper Functions ===

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
  rescue
    # If there's any error generating args, consider it problematic
    _ -> true
  end

  # Consolidated shared logic for video deletion
  defp delete_videos_by_ids(video_ids) do
    Repo.transaction(fn ->
      from(v in Vmaf, where: v.video_id in ^video_ids) |> Repo.delete_all()
      from(v in Video, where: v.id in ^video_ids) |> Repo.delete_all()
    end)
  end

  defp get_video_ids_with_missing_files do
    from(v in Video, select: %{id: v.id, path: v.path})
    |> Repo.all()
    |> Enum.filter(&file_missing?/1)
    |> Enum.map(& &1.id)
  end

  defp file_missing?(%{path: path}), do: not File.exists?(path)
end
