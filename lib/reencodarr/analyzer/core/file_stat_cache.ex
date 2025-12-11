defmodule Reencodarr.Analyzer.Core.FileStatCache do
  @moduledoc """
  Caches file stat information to avoid repeated filesystem calls.

  Maintains a cache of file existence, modification time, and size
  to optimize analyzer performance by reducing syscalls.
  """
  use GenServer
  require Logger

  @cache_ttl :timer.minutes(5)
  @cache_cleanup_interval :timer.minutes(10)

  defstruct [:cache, :cache_timers]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
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
    GenServer.call(__MODULE__, {:get_stats, path})
  end

  @doc """
  Bulk get file stats for multiple paths.
  More efficient than individual calls for large batches.
  """
  @spec get_bulk_file_stats([String.t()]) :: %{String.t() => {:ok, map()} | {:error, term()}}
  def get_bulk_file_stats(paths) when is_list(paths) do
    GenServer.call(__MODULE__, {:get_bulk_stats, paths})
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
    GenServer.cast(__MODULE__, {:invalidate, path})
  end

  @doc """
  Clear all cache entries.
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    GenServer.cast(__MODULE__, :clear_cache)
  end

  # GenServer callbacks

  @impl GenServer
  def init(_args) do
    # Schedule periodic cache cleanup
    Process.send_after(self(), :cleanup_expired, @cache_cleanup_interval)

    {:ok,
     %__MODULE__{
       cache: %{},
       cache_timers: %{}
     }}
  end

  @impl GenServer
  def handle_call({:get_stats, path}, _from, state) do
    case get_cached_stats(path, state.cache) do
      :cache_miss ->
        # Cache miss - fetch fresh stats
        {result, new_state} = fetch_and_cache_stats(path, state)
        {:reply, result, new_state}

      cached_result ->
        # Cache hit
        {:reply, cached_result, state}
    end
  end

  @impl GenServer
  def handle_call({:get_bulk_stats, paths}, _from, state) do
    {results, new_state} = get_bulk_stats_with_cache(paths, state)
    {:reply, results, new_state}
  end

  @impl GenServer
  def handle_cast({:invalidate, path}, state) do
    new_cache = Map.delete(state.cache, path)
    new_timers = Map.delete(state.cache_timers, path)

    {:noreply, %{state | cache: new_cache, cache_timers: new_timers}}
  end

  @impl GenServer
  def handle_cast(:clear_cache, state) do
    # Cancel all timers
    Enum.each(state.cache_timers, fn {_path, timer_ref} ->
      Process.cancel_timer(timer_ref)
    end)

    {:noreply, %__MODULE__{cache: %{}, cache_timers: %{}}}
  end

  @impl GenServer
  def handle_info({:expire_cache, path}, state) do
    new_cache = Map.delete(state.cache, path)
    new_timers = Map.delete(state.cache_timers, path)

    {:noreply, %{state | cache: new_cache, cache_timers: new_timers}}
  end

  @impl GenServer
  def handle_info(:cleanup_expired, state) do
    # Schedule next cleanup
    Process.send_after(self(), :cleanup_expired, @cache_cleanup_interval)

    # Clean up expired entries
    now = System.monotonic_time(:millisecond)
    cutoff = now - @cache_ttl

    {expired_keys, active_cache} =
      Enum.reduce(state.cache, {[], %{}}, fn {path, {result, timestamp}}, {expired, active} ->
        if timestamp < cutoff do
          {[path | expired], active}
        else
          {expired, Map.put(active, path, {result, timestamp})}
        end
      end)

    # Cancel timers for expired entries
    expired_timers = Map.take(state.cache_timers, expired_keys)

    Enum.each(expired_timers, fn {_path, timer_ref} ->
      Process.cancel_timer(timer_ref)
    end)

    new_timers = Map.drop(state.cache_timers, expired_keys)
    expired_count = length(expired_keys)

    if expired_count > 0 do
      Logger.debug("FileStatCache: Cleaned up #{expired_count} expired entries")
    end

    {:noreply, %{state | cache: active_cache, cache_timers: new_timers}}
  end

  # Private functions

  defp get_cached_stats(path, cache) do
    case Map.get(cache, path) do
      {result, _timestamp} -> result
      nil -> :cache_miss
    end
  end

  defp fetch_and_cache_stats(path, state) do
    result = fetch_file_stats(path)

    # Cache the result with timestamp
    timestamp = System.monotonic_time(:millisecond)
    new_cache = Map.put(state.cache, path, {result, timestamp})

    # Set expiration timer
    timer_ref = Process.send_after(self(), {:expire_cache, path}, @cache_ttl)
    new_timers = Map.put(state.cache_timers, path, timer_ref)

    new_state = %{state | cache: new_cache, cache_timers: new_timers}
    {result, new_state}
  end

  defp get_bulk_stats_with_cache(paths, state) do
    {results, new_state} =
      Enum.reduce(paths, {%{}, state}, fn path, {acc_results, acc_state} ->
        case get_cached_stats(path, acc_state.cache) do
          :cache_miss ->
            {result, updated_state} = fetch_and_cache_stats(path, acc_state)
            {Map.put(acc_results, path, result), updated_state}

          cached_result ->
            {Map.put(acc_results, path, cached_result), acc_state}
        end
      end)

    {results, new_state}
  end

  defp fetch_file_stats(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, mtime: mtime, size: size}} ->
        {:ok, %{exists: true, mtime: mtime, size: size, type: :regular}}

      {:ok, %File.Stat{type: type}} ->
        # Not a regular file (directory, device, etc.)
        {:ok, %{exists: true, type: type}}

      {:error, :enoent} ->
        {:ok, %{exists: false}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
