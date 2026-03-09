defmodule Reencodarr.Analyzer.Core.FileStatCache do
  @moduledoc """
  Caches file stat information to avoid repeated filesystem calls.

  Maintains a cache of file existence, modification time, and size
  to optimize analyzer performance by reducing syscalls.

  Backed by Cachex with a 5-minute TTL and automatic expiration.
  """
  import Cachex.Spec

  @cache_name :file_stat_cache

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  def start_link(_opts) do
    Cachex.start_link(@cache_name,
      expiration: expiration(default: :timer.minutes(5), interval: :timer.minutes(1), lazy: true)
    )
  end

  @doc """
  Get file stats (exists?, mtime, size) with caching.

  Returns:
  - `{:ok, %{exists: true, mtime: integer(), size: integer()}}` for existing files
  - `{:ok, %{exists: false}}` for non-existent files
  - `{:error, reason}` for filesystem errors
  """
  @spec get_file_stats(String.t()) :: {:ok, map()} | {:error, term()}
  def get_file_stats(path) when is_binary(path) do
    case Cachex.fetch(@cache_name, path, fn _key -> {:commit, do_file_stat(path)} end) do
      {status, result} when status in [:ok, :commit] -> result
      {:error, _} = error -> error
    end
  end

  @doc """
  Bulk get file stats for multiple paths.
  More efficient than individual calls for large batches.
  """
  @spec get_bulk_file_stats([String.t()]) :: %{String.t() => {:ok, map()} | {:error, term()}}
  def get_bulk_file_stats(paths) when is_list(paths) do
    Map.new(paths, fn path -> {path, get_file_stats(path)} end)
  end

  @doc """
  Check if a file exists (cached).
  """
  @spec file_exists?(String.t()) :: boolean()
  def file_exists?(path) do
    case get_file_stats(path) do
      {:ok, %{exists: exists}} -> exists
      _ -> false
    end
  end

  @doc """
  Clear cache entry for a specific path.
  Useful when we know a file has been modified.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(path) do
    Cachex.del(@cache_name, path)
    :ok
  end

  @doc """
  Clear all cache entries.
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    Cachex.clear(@cache_name)
    :ok
  end

  # Domain logic

  defp do_file_stat(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, mtime: mtime, size: size}} ->
        {:ok, %{exists: true, mtime: mtime, size: size, type: :regular}}

      {:ok, %File.Stat{type: type}} ->
        {:ok, %{exists: true, type: type}}

      {:error, :enoent} ->
        {:ok, %{exists: false}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
