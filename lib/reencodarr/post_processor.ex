defmodule Reencodarr.PostProcessor do
  @moduledoc """
  Handles post-encoding operations including file moves, database updates, and syncing.

  This module manages the pipeline after successful encoding:
  1. Move output to intermediate location
  2. Reload video from database
  3. Mark as reencoded
  4. Finalize file location
  5. Trigger sync operations
  """

  require Logger

  alias Reencodarr.{FileOperations, Media, Repo, Sync}

  @spec process_encoding_success(video :: any(), output_file :: String.t()) ::
          {:ok, :success} | {:error, atom()}
  def process_encoding_success(video, output_file) do
    intermediate_path = FileOperations.calculate_intermediate_path(video)

    case move_to_intermediate(output_file, intermediate_path, video) do
      {:ok, actual_path} ->
        process_intermediate_success(video, actual_path)
        {:ok, :success}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec process_encoding_failure(video :: any(), exit_code :: integer(), context :: map()) :: :ok
  def process_encoding_failure(video, exit_code, context \\ %{}) do
    Logger.error(
      "Encoding failed for video #{video.id} (#{video.path}) with exit code #{exit_code}. Marking as failed."
    )

    # Record detailed failure information with enhanced context
    Reencodarr.FailureTracker.record_process_failure(video, exit_code, context: context)

    :ok
  end

  @spec move_to_intermediate(String.t(), String.t(), any()) ::
          {:ok, String.t()} | {:error, atom()}

  defp move_to_intermediate(output_file, intermediate_path, video) do
    case FileOperations.move_file(output_file, intermediate_path, "IntermediateMove", video) do
      :ok ->
        Logger.info(
          "[IntermediateMove] Encoder output #{output_file} successfully placed at intermediate path #{intermediate_path} for video #{video.id}"
        )

        {:ok, intermediate_path}

      {:error, reason} ->
        Logger.error(
          "[IntermediateMove] Failed to place encoder output at intermediate path #{intermediate_path} for video #{video.id}. Marking as failed."
        )

        # Record detailed file operation failure
        Reencodarr.FailureTracker.record_file_operation_failure(
          video,
          :move,
          output_file,
          intermediate_path,
          reason
        )

        {:error, :failed_to_move_to_intermediate}
    end
  end

  @spec process_intermediate_success(any(), String.t()) :: :ok

  defp process_intermediate_success(video, actual_path) do
    case Repo.reload(video) do
      nil ->
        Logger.error("Failed to reload video #{video.id}: Video not found.")
        :ok

      reloaded ->
        process_reloaded_video(reloaded, actual_path)
    end
  end

  @spec process_reloaded_video(any(), String.t()) :: :ok

  defp process_reloaded_video(video, actual_path) do
    case Media.mark_as_reencoded(video) do
      {:ok, _} ->
        Logger.info("Successfully marked video #{video.id} as re-encoded")
        finalize_and_sync(video, actual_path)

      {:error, reason} ->
        Logger.error("Failed to mark video #{video.id} as re-encoded: #{inspect(reason)}")
        :ok
    end
  end

  @spec finalize_and_sync(any(), String.t()) :: :ok

  defp finalize_and_sync(video, intermediate_path) do
    case FileOperations.move_file(intermediate_path, video.path, "FinalRename", video) do
      :ok ->
        Logger.info(
          "[FinalRename] Successfully finalized re-encoded file from #{intermediate_path} to #{video.path} for video #{video.id}"
        )

      {:error, _reason} ->
        Logger.error(
          "[FinalRename] Failed to finalize re-encoded file from #{intermediate_path} to #{video.path} for video #{video.id}. " <>
            "The file may remain at #{intermediate_path}. Sync will still be called."
        )
    end

    # Always call Sync as per original logic
    Logger.info(
      "Calling Sync.refresh_and_rename_from_video for video #{video.id} (path: #{video.path}) after finalization attempt."
    )

    Sync.refresh_and_rename_from_video(video)
  end
end
