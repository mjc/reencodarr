defmodule Reencodarr.Analyzer.MediaInfoCache do
  @moduledoc """
  Caches mediainfo results based on file modification time.

  Avoids re-running mediainfo for files that haven't changed,
  significantly improving analyzer performance for re-analysis scenarios.
  """
  use GenServer
  require Logger

  alias Reencodarr.Analyzer.Core.FileStatCache

  @cache_cleanup_interval :timer.minutes(15)
  # Keep mediainfo cache for 1 hour
  @cache_ttl :timer.hours(1)
  # Maximum cache size (number of entries)
  @max_cache_size 1000

  defstruct [:cache, :access_times, :cache_size]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Get cached mediainfo for a file, or fetch fresh if cache miss/invalidated.

  Returns:
  - `{:ok, mediainfo_data}` for successful cache hit or fresh fetch
  - `{:error, reason}` for filesystem or mediainfo errors
  """
  @spec get_mediainfo(String.t()) :: {:ok, map()} | {:error, term()}
  def get_mediainfo(path) when is_binary(path) do
    GenServer.call(__MODULE__, {:get_mediainfo, path}, :timer.minutes(10))
  end

  @doc """
  Get mediainfo for multiple files efficiently.
  Uses bulk file stat checking and batch mediainfo execution.
  """
  @spec get_bulk_mediainfo([String.t()]) :: %{String.t() => {:ok, map()} | {:error, term()}}
  def get_bulk_mediainfo(paths) when is_list(paths) do
    GenServer.call(__MODULE__, {:get_bulk_mediainfo, paths}, :timer.minutes(15))
  end

  @doc """
  Invalidate cached mediainfo for a specific file.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(path) do
    GenServer.cast(__MODULE__, {:invalidate, path})
  end

  @doc """
  Clear all cached mediainfo entries.
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    GenServer.cast(__MODULE__, :clear_cache)
  end

  @doc """
  Get cache statistics for monitoring.
  """
  @spec get_stats() :: map()
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  # GenServer callbacks

  @impl GenServer
  def init(_args) do
    # Schedule periodic cache cleanup
    Process.send_after(self(), :cleanup_cache, @cache_cleanup_interval)

    {:ok,
     %__MODULE__{
       cache: %{},
       access_times: %{},
       cache_size: 0
     }}
  end

  @impl GenServer
  def handle_call({:get_mediainfo, path}, _from, state) do
    case get_cached_mediainfo(path, state) do
      {:cache_hit, result, new_state} ->
        {:reply, result, new_state}

      {:cache_miss, new_state} ->
        {result, final_state} = fetch_and_cache_mediainfo(path, new_state)
        {:reply, result, final_state}
    end
  end

  @impl GenServer
  def handle_call({:get_bulk_mediainfo, paths}, _from, state) do
    {results, new_state} = get_bulk_mediainfo_with_cache(paths, state)
    {:reply, results, new_state}
  end

  @impl GenServer
  def handle_call(:get_stats, _from, state) do
    stats = %{
      cache_size: state.cache_size,
      max_cache_size: @max_cache_size,
      cache_utilization: state.cache_size / @max_cache_size
    }

    {:reply, stats, state}
  end

  @impl GenServer
  def handle_cast({:invalidate, path}, state) do
    new_state = remove_from_cache(path, state)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_cast(:clear_cache, _state) do
    {:noreply, %__MODULE__{cache: %{}, access_times: %{}, cache_size: 0}}
  end

  @impl GenServer
  def handle_info(:cleanup_cache, state) do
    # Schedule next cleanup
    Process.send_after(self(), :cleanup_cache, @cache_cleanup_interval)

    # Clean up expired entries and enforce size limits
    new_state = cleanup_expired_and_enforce_limits(state)

    {:noreply, new_state}
  end

  # Private functions

  defp get_cached_mediainfo(path, state) do
    case Map.get(state.cache, path) do
      nil ->
        {:cache_miss, state}

      {cached_data, cached_mtime} ->
        # Check if file has been modified since cache
        case FileStatCache.get_file_stats(path) do
          {:ok, %{exists: true, mtime: current_mtime}} when current_mtime == cached_mtime ->
            # Cache hit - file unchanged
            new_access_times =
              Map.put(state.access_times, path, System.monotonic_time(:millisecond))

            new_state = %{state | access_times: new_access_times}
            {:cache_hit, {:ok, cached_data}, new_state}

          {:ok, %{exists: true}} ->
            # File modified - cache invalid
            Logger.debug("MediaInfoCache: File modified, invalidating cache for #{path}")
            new_state = remove_from_cache(path, state)
            {:cache_miss, new_state}

          {:ok, %{exists: false}} ->
            # File no longer exists
            Logger.debug("MediaInfoCache: File no longer exists, removing from cache: #{path}")
            new_state = remove_from_cache(path, state)
            {:cache_miss, new_state}

          {:error, _reason} ->
            # Can't stat file - assume cache invalid
            new_state = remove_from_cache(path, state)
            {:cache_miss, new_state}
        end
    end
  end

  defp fetch_and_cache_mediainfo(path, state) do
    # First check if file exists using cached file stats
    case FileStatCache.get_file_stats(path) do
      {:ok, %{exists: true, mtime: mtime}} ->
        # File exists, fetch mediainfo
        case execute_mediainfo(path) do
          {:ok, mediainfo_data} ->
            # Cache the result
            new_state = add_to_cache(path, mediainfo_data, mtime, state)
            {{:ok, mediainfo_data}, new_state}

          {:error, _reason} = error ->
            {error, state}
        end

      {:ok, %{exists: false}} ->
        {{:error, :file_not_found}, state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp get_bulk_mediainfo_with_cache(paths, state) do
    # First, separate cached vs uncached paths
    {cached_results, uncached_paths, intermediate_state} =
      Enum.reduce(paths, {%{}, [], state}, fn path, {acc_results, acc_uncached, acc_state} ->
        case get_cached_mediainfo(path, acc_state) do
          {:cache_hit, result, new_state} ->
            {Map.put(acc_results, path, result), acc_uncached, new_state}

          {:cache_miss, new_state} ->
            {acc_results, [path | acc_uncached], new_state}
        end
      end)

    # Fetch mediainfo for uncached paths
    {fresh_results, final_state} =
      if uncached_paths != [] do
        fetch_bulk_mediainfo(uncached_paths, intermediate_state)
      else
        {%{}, intermediate_state}
      end

    # Combine cached and fresh results
    all_results = Map.merge(cached_results, fresh_results)
    {all_results, final_state}
  end

  defp fetch_bulk_mediainfo(paths, state) do
    # Get file stats for all paths
    file_stats = FileStatCache.get_bulk_file_stats(paths)

    # Filter to existing files and extract their paths
    {existing_paths, path_to_mtime} = extract_existing_paths(file_stats)

    # Execute batch mediainfo for existing files
    batch_results = execute_batch_if_needed(existing_paths)

    process_bulk_mediainfo_results(paths, file_stats, path_to_mtime, batch_results, state)
  end

  defp extract_existing_paths(file_stats) do
    Enum.reduce(file_stats, {[], %{}}, fn {path, stat_result}, {acc_paths, acc_mtimes} ->
      case stat_result do
        {:ok, %{exists: true, mtime: mtime}} ->
          {[path | acc_paths], Map.put(acc_mtimes, path, mtime)}

        _ ->
          {acc_paths, acc_mtimes}
      end
    end)
  end

  defp execute_batch_if_needed([]), do: {:ok, %{}}
  defp execute_batch_if_needed(existing_paths), do: execute_batch_mediainfo(existing_paths)

  defp process_bulk_mediainfo_results(paths, file_stats, path_to_mtime, batch_results, state) do
    case batch_results do
      {:ok, mediainfo_map} ->
        process_successful_bulk_results(paths, file_stats, path_to_mtime, mediainfo_map, state)

      {:error, reason} ->
        process_failed_bulk_results(paths, reason, state)
    end
  end

  defp process_successful_bulk_results(paths, file_stats, path_to_mtime, mediainfo_map, state) do
    Enum.reduce(paths, {%{}, state}, fn path, {acc_results, acc_state} ->
      result_for_path = determine_path_result(path, file_stats, path_to_mtime, mediainfo_map)

      {updated_results, updated_state} =
        update_results_and_cache(path, result_for_path, acc_results, acc_state)

      {updated_results, updated_state}
    end)
  end

  defp determine_path_result(path, file_stats, path_to_mtime, mediainfo_map) do
    cond do
      Map.get(file_stats, path) == {:ok, %{exists: false}} ->
        {:error, :file_not_found}

      Map.has_key?(mediainfo_map, path) ->
        mediainfo_data = Map.get(mediainfo_map, path)
        mtime = Map.get(path_to_mtime, path)
        {:ok, mediainfo_data, mtime}

      true ->
        {:error, :mediainfo_failed}
    end
  end

  defp update_results_and_cache(path, result_for_path, acc_results, acc_state) do
    case result_for_path do
      {:ok, mediainfo_data, mtime} ->
        updated_state = add_to_cache(path, mediainfo_data, mtime, acc_state)
        {Map.put(acc_results, path, {:ok, mediainfo_data}), updated_state}

      {:error, reason} ->
        {Map.put(acc_results, path, {:error, reason}), acc_state}
    end
  end

  defp process_failed_bulk_results(paths, reason, state) do
    error_results =
      Enum.reduce(paths, %{}, fn path, acc ->
        Map.put(acc, path, {:error, reason})
      end)

    {error_results, state}
  end

  defp execute_mediainfo(path) do
    case System.cmd("mediainfo", ["--Output=JSON", path], stderr_to_stdout: true) do
      {json, 0} ->
        case Jason.decode(json) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, {:json_decode, reason}}
        end

      {error_msg, code} ->
        Logger.warning("MediaInfo failed for #{path}: #{error_msg}")
        {:error, {:mediainfo_failed, code, error_msg}}
    end
  end

  defp execute_batch_mediainfo([]), do: {:ok, %{}}

  defp execute_batch_mediainfo(paths) when is_list(paths) and paths != [] do
    Logger.debug("MediaInfoCache: Executing batch mediainfo for #{length(paths)} files")

    case System.cmd("mediainfo", ["--Output=JSON" | paths], stderr_to_stdout: true) do
      {json, 0} ->
        process_mediainfo_json(json, paths)

      {error_msg, code} ->
        Logger.error("Batch mediainfo failed: #{error_msg}")
        {:error, {:mediainfo_failed, code, error_msg}}
    end
  end

  defp process_mediainfo_json(json, paths) do
    case Jason.decode(json) do
      {:ok, data} when is_list(data) ->
        # Parse batch results into path -> mediainfo map
        parse_batch_mediainfo_results(data, paths)

      {:ok, single_result} ->
        handle_single_mediainfo_result(single_result, paths)

      {:error, reason} ->
        {:error, {:json_decode, reason}}
    end
  end

  defp handle_single_mediainfo_result(single_result, paths) do
    # Single file result
    if length(paths) == 1 do
      {:ok, %{List.first(paths) => single_result}}
    else
      {:error, {:unexpected_single_result, length(paths)}}
    end
  end

  defp parse_batch_mediainfo_results(media_info_list, original_paths) do
    # If we have the same number of results as requested paths, we can map them by index
    if length(media_info_list) == length(original_paths) do
      parse_by_index_mapping(media_info_list, original_paths)
    else
      parse_by_path_extraction(media_info_list, original_paths)
    end
  end

  defp parse_by_index_mapping(media_info_list, original_paths) do
    result_map =
      Enum.zip(original_paths, media_info_list)
      |> Enum.reduce(%{}, fn {path, media_info}, acc ->
        Map.put(acc, path, media_info)
      end)

    {:ok, result_map}
  end

  defp parse_by_path_extraction(media_info_list, original_paths) do
    result_map =
      Enum.reduce(media_info_list, %{}, fn media_info, acc ->
        case extract_complete_name(media_info) do
          {:ok, path} ->
            Map.put(acc, path, media_info)

          {:error, reason} ->
            log_path_extraction_failure(media_info, reason, original_paths)
            acc
        end
      end)

    {:ok, result_map}
  end

  defp log_path_extraction_failure(media_info, reason, original_paths) do
    media_debug = inspect(media_info, limit: :infinity, printable_limit: 200)

    Logger.warning(
      "Failed to extract complete name from mediainfo result: #{reason}. " <>
        "Requested paths: #{inspect(original_paths)}. Media info: #{media_debug}"
    )
  end

  defp extract_complete_name(%{"@ref" => path}) when is_binary(path), do: {:ok, path}

  defp extract_complete_name(%{"media" => media_item}) do
    extract_from_media_tracks(media_item)
  end

  defp extract_complete_name(%{"track" => tracks}) when is_list(tracks) do
    extract_from_tracks(tracks)
  end

  defp extract_complete_name(_), do: {:error, "invalid media info structure"}

  defp extract_from_media_tracks(%{"track" => tracks}) when is_list(tracks) do
    extract_from_tracks(tracks)
  end

  defp extract_from_media_tracks(_), do: {:error, "invalid media structure"}

  defp extract_from_tracks(tracks) do
    case Enum.find(tracks, &(Map.get(&1, "@type") == "General")) do
      %{"Complete_name" => path} when is_binary(path) ->
        {:ok, path}

      %{"CompleteName" => path} when is_binary(path) ->
        {:ok, path}

      _ ->
        {:error, "no Complete_name or CompleteName in General track"}
    end
  end

  defp add_to_cache(path, data, mtime, state) do
    # Enforce cache size limit before adding
    state_after_cleanup =
      if state.cache_size >= @max_cache_size do
        evict_least_recently_used(state)
      else
        state
      end

    # Add new entry
    now = System.monotonic_time(:millisecond)
    new_cache = Map.put(state_after_cleanup.cache, path, {data, mtime})
    new_access_times = Map.put(state_after_cleanup.access_times, path, now)

    %{
      state_after_cleanup
      | cache: new_cache,
        access_times: new_access_times,
        cache_size: state_after_cleanup.cache_size + 1
    }
  end

  defp remove_from_cache(path, state) do
    if Map.has_key?(state.cache, path) do
      %{
        state
        | cache: Map.delete(state.cache, path),
          access_times: Map.delete(state.access_times, path),
          cache_size: state.cache_size - 1
      }
    else
      state
    end
  end

  defp evict_least_recently_used(state) do
    if state.cache_size > 0 do
      # Find least recently used entry
      {lru_path, _lru_time} = Enum.min_by(state.access_times, fn {_path, time} -> time end)
      remove_from_cache(lru_path, state)
    else
      state
    end
  end

  defp cleanup_expired_and_enforce_limits(state) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - @cache_ttl

    # Remove expired entries
    {expired_paths, active_access_times} =
      Enum.reduce(state.access_times, {[], %{}}, fn {path, access_time}, {expired, active} ->
        if access_time < cutoff do
          {[path | expired], active}
        else
          {expired, Map.put(active, path, access_time)}
        end
      end)

    # Remove expired entries from cache
    active_cache = Map.drop(state.cache, expired_paths)
    new_cache_size = state.cache_size - length(expired_paths)

    if length(expired_paths) > 0 do
      Logger.debug("MediaInfoCache: Cleaned up #{length(expired_paths)} expired entries")
    end

    # Enforce size limits by evicting LRU entries if needed
    intermediate_state = %{
      state
      | cache: active_cache,
        access_times: active_access_times,
        cache_size: new_cache_size
    }

    # Evict excess entries if still over limit
    final_state =
      if intermediate_state.cache_size > @max_cache_size do
        excess_count = intermediate_state.cache_size - @max_cache_size

        Enum.reduce(1..excess_count, intermediate_state, fn _i, acc_state ->
          evict_least_recently_used(acc_state)
        end)
      else
        intermediate_state
      end

    final_state
  end
end
