defmodule Reencodarr.Analyzer.Core.FileOperations do
  @moduledoc """
  Consolidated file operations for analyzer with high-performance optimizations.

  This module eliminates duplication by centralizing all file system operations
  used across the analyzer components.

  Features:
  - Bulk file existence checking
  - Cached file statistics
  - Batch file operations
  - Storage-aware concurrency
  """

  require Logger
  alias Reencodarr.Analyzer.{Core.FileStatCache, Optimization.BulkFileChecker}

  @doc """
  Check if multiple files exist efficiently.

  Uses bulk operations optimized for high-performance storage.
  """
  @spec check_files_exist([String.t()]) :: %{String.t() => boolean()}
  def check_files_exist(paths) when is_list(paths) do
    BulkFileChecker.check_files_exist(paths)
  end

  @doc """
  Check if a single file exists with caching.
  """
  @spec file_exists?(String.t()) :: boolean()
  def file_exists?(path) when is_binary(path) do
    FileStatCache.file_exists?(path)
  end

  @doc """
  Get file stats with caching for better performance.
  """
  @spec get_file_stats(String.t()) :: {:ok, map()} | {:error, term()}
  def get_file_stats(path) when is_binary(path) do
    FileStatCache.get_file_stats(path)
  end

  @doc """
  Get file stats for multiple files efficiently.
  """
  @spec get_bulk_file_stats([String.t()]) :: %{String.t() => {:ok, map()} | {:error, term()}}
  def get_bulk_file_stats(paths) when is_list(paths) do
    FileStatCache.get_bulk_file_stats(paths)
  end

  @doc """
  Filter a list of paths to only existing files.

  Uses bulk checking for optimal performance.
  """
  @spec filter_existing_files([String.t()]) :: [String.t()]
  def filter_existing_files(paths) when is_list(paths) do
    existence_map = check_files_exist(paths)

    Enum.filter(paths, fn path ->
      Map.get(existence_map, path, false)
    end)
  end

  @doc """
  Validate file accessibility for processing.

  Checks existence, readability, and basic file properties.
  """
  @spec validate_file_for_processing(String.t()) :: {:ok, map()} | {:error, term()}
  def validate_file_for_processing(path) when is_binary(path) do
    with {:ok, stats} <- get_file_stats(path),
         :ok <- validate_file_accessibility(path, stats) do
      {:ok, stats}
    else
      error -> error
    end
  end

  @doc """
  Validate multiple files for processing efficiently.
  """
  @spec validate_files_for_processing([String.t()]) :: %{
          String.t() => {:ok, map()} | {:error, term()}
        }
  def validate_files_for_processing(paths) when is_list(paths) do
    stats_map = get_bulk_file_stats(paths)

    Map.new(paths, &validate_file_from_stats(&1, stats_map))
  end

  defp validate_file_from_stats(path, stats_map) do
    case Map.get(stats_map, path) do
      {:ok, stats} ->
        case validate_file_accessibility(path, stats) do
          :ok -> {path, {:ok, stats}}
          error -> {path, error}
        end

      error ->
        {path, error}
    end
  end

  # Private functions

  defp validate_file_accessibility(path, %{exists: false}) do
    {:error, "file does not exist: #{path}"}
  end

  defp validate_file_accessibility(path, %{exists: true, size: 0}) do
    {:error, "file is empty: #{path}"}
  end

  defp validate_file_accessibility(path, %{exists: true}) do
    # Additional checks can be added here (permissions, file type, etc.)
    case File.stat(path) do
      {:ok, _file_stat} -> :ok
      {:error, reason} -> {:error, "file not accessible: #{path} (#{reason})"}
    end
  end

  defp validate_file_accessibility(_path, _stats) do
    {:error, "invalid file stats"}
  end
end
