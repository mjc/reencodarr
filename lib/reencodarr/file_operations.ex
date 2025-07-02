defmodule Reencodarr.FileOperations do
  @moduledoc """
  Handles all file operations including cross-device moves, renames, and copies.

  This module provides robust file operations that handle edge cases like
  cross-device operations (EXDEV errors) and provides detailed logging.
  """

  require Logger

  @spec move_file(
          source :: String.t(),
          destination :: String.t(),
          context :: String.t(),
          video :: any()
        ) :: :ok | {:error, any()}
  def move_file(source, destination, context, video) do
    case File.rename(source, destination) do
      :ok ->
        Logger.info(
          "[#{context}] Successfully renamed #{source} to #{destination} for video #{video.id}"
        )

        :ok

      {:error, :exdev} ->
        handle_cross_device_move(source, destination, context, video)

      {:error, reason} ->
        Logger.error(
          "[#{context}] Failed to rename #{source} to #{destination} for video #{video.id}: #{reason}. File remains at #{source}."
        )

        {:error, reason}
    end
  end

  @spec handle_cross_device_move(
          source :: String.t(),
          destination :: String.t(),
          context :: String.t(),
          video :: any()
        ) :: :ok | {:error, any()}

  defp handle_cross_device_move(source, destination, context, video) do
    Logger.info(
      "[#{context}] Cross-device rename for #{source} to #{destination} (video #{video.id}). Attempting copy and delete."
    )

    case File.cp(source, destination) do
      :ok ->
        Logger.info(
          "[#{context}] Successfully copied #{source} to #{destination} for video #{video.id}"
        )

        cleanup_original_file(source, context, video)

      {:error, cp_reason} ->
        Logger.error(
          "[#{context}] Failed to copy #{source} to #{destination} for video #{video.id}: #{cp_reason}. File remains at #{source}."
        )

        {:error, cp_reason}
    end
  end

  @spec cleanup_original_file(source :: String.t(), context :: String.t(), video :: any()) :: :ok

  defp cleanup_original_file(source, context, video) do
    case File.rm(source) do
      :ok ->
        Logger.info(
          "[#{context}] Successfully removed original file #{source} after copy for video #{video.id}"
        )

      {:error, rm_reason} ->
        Logger.error(
          "[#{context}] Failed to remove original file #{source} after copy for video #{video.id}: #{rm_reason}"
        )
    end

    :ok
  end

  @spec calculate_intermediate_path(video :: any()) :: String.t()
  def calculate_intermediate_path(video) do
    Path.join(
      Path.dirname(video.path),
      Path.basename(video.path, Path.extname(video.path)) <>
        ".reencoded" <> Path.extname(video.path)
    )
  end
end
