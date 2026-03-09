defmodule Reencodarr.Analyzer.MediaInfoCache do
  @moduledoc """
  Caches mediainfo results based on file modification time.

  Avoids re-running mediainfo for files that haven't changed,
  significantly improving analyzer performance for re-analysis scenarios.

  Backed by Cachex with a 1-hour TTL. Cache entries are invalidated when
  the file's mtime changes, ensuring stale data is never returned.
  """
  require Logger
  import Cachex.Spec

  alias Reencodarr.Analyzer.Core.FileStatCache

  @cache_name :mediainfo_cache
  @max_cache_size 1000

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  def start_link(_opts) do
    Cachex.start_link(@cache_name,
      expiration: expiration(default: :timer.hours(1), interval: :timer.minutes(5), lazy: true)
    )
  end

  @doc """
  Get cached mediainfo for a file, or fetch fresh if cache miss/invalidated.

  Returns:
  - `{:ok, mediainfo_data}` for successful cache hit or fresh fetch
  - `{:error, reason}` for filesystem or mediainfo errors
  """
  @spec get_mediainfo(String.t()) :: {:ok, map()} | {:error, term()}
  def get_mediainfo(path) when is_binary(path) do
    case Cachex.get(@cache_name, path) do
      {:ok, {cached_data, cached_mtime}} ->
        validate_and_return(path, cached_data, cached_mtime)

      {:ok, nil} ->
        fetch_and_cache_mediainfo(path)

      {:error, _} ->
        fetch_and_cache_mediainfo(path)
    end
  end

  @doc """
  Get mediainfo for multiple files efficiently.
  Uses bulk file stat checking and batch mediainfo execution.
  """
  @spec get_bulk_mediainfo([String.t()]) :: %{String.t() => {:ok, map()} | {:error, term()}}
  def get_bulk_mediainfo(paths) when is_list(paths) do
    {cached_results, uncached_paths} = separate_cached_and_uncached(paths)

    fresh_results =
      if uncached_paths != [] do
        fetch_bulk_mediainfo(uncached_paths)
      else
        %{}
      end

    Map.merge(cached_results, fresh_results)
  end

  @doc """
  Invalidate cached mediainfo for a specific file.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(path) do
    Cachex.del(@cache_name, path)
    :ok
  end

  @doc """
  Clear all cached mediainfo entries.
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    Cachex.clear(@cache_name)
    :ok
  end

  @doc """
  Get cache statistics for monitoring.
  """
  @spec get_stats() :: map()
  def get_stats do
    {:ok, size} = Cachex.size(@cache_name)

    %{
      cache_size: size,
      max_cache_size: @max_cache_size,
      cache_utilization: size / @max_cache_size
    }
  end

  # Private functions

  defp validate_and_return(path, cached_data, cached_mtime) do
    case FileStatCache.get_file_stats(path) do
      {:ok, %{exists: true, mtime: ^cached_mtime}} ->
        {:ok, cached_data}

      {:ok, %{exists: true}} ->
        Logger.debug("MediaInfoCache: File modified, invalidating cache for #{path}")
        Cachex.del(@cache_name, path)
        fetch_and_cache_mediainfo(path)

      {:ok, %{exists: false}} ->
        Logger.debug("MediaInfoCache: File no longer exists, removing from cache: #{path}")
        Cachex.del(@cache_name, path)
        {:error, :file_not_found}

      {:error, _reason} ->
        Cachex.del(@cache_name, path)
        fetch_and_cache_mediainfo(path)
    end
  end

  defp fetch_and_cache_mediainfo(path) do
    case FileStatCache.get_file_stats(path) do
      {:ok, %{exists: true, mtime: mtime}} ->
        case execute_mediainfo(path) do
          {:ok, mediainfo_data} ->
            maybe_prune()
            Cachex.put(@cache_name, path, {mediainfo_data, mtime})
            {:ok, mediainfo_data}

          {:error, _reason} = error ->
            error
        end

      {:ok, %{exists: false}} ->
        {:error, :file_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp separate_cached_and_uncached(paths) do
    Enum.reduce(paths, {%{}, []}, fn path, {cached, uncached} ->
      case check_cached(path) do
        {:ok, _} = result -> {Map.put(cached, path, result), uncached}
        :miss -> {cached, [path | uncached]}
      end
    end)
  end

  defp check_cached(path) do
    case Cachex.get(@cache_name, path) do
      {:ok, {cached_data, cached_mtime}} ->
        validate_cached_entry(path, cached_data, cached_mtime)

      _ ->
        :miss
    end
  end

  defp validate_cached_entry(path, cached_data, cached_mtime) do
    case FileStatCache.get_file_stats(path) do
      {:ok, %{exists: true, mtime: ^cached_mtime}} ->
        {:ok, cached_data}

      _ ->
        Cachex.del(@cache_name, path)
        :miss
    end
  end

  defp fetch_bulk_mediainfo(paths) do
    file_stats = FileStatCache.get_bulk_file_stats(paths)
    {existing_paths, path_to_mtime} = extract_existing_paths(file_stats)
    batch_results = execute_batch_if_needed(existing_paths)
    process_bulk_mediainfo_results(paths, file_stats, path_to_mtime, batch_results)
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

  defp process_bulk_mediainfo_results(paths, file_stats, path_to_mtime, batch_results) do
    case batch_results do
      {:ok, mediainfo_map} ->
        maybe_prune()

        Map.new(paths, fn path ->
          {path, cache_and_return(path, file_stats, path_to_mtime, mediainfo_map)}
        end)

      {:error, reason} ->
        Map.new(paths, fn path -> {path, {:error, reason}} end)
    end
  end

  defp cache_and_return(path, file_stats, path_to_mtime, mediainfo_map) do
    cond do
      Map.get(file_stats, path) == {:ok, %{exists: false}} ->
        {:error, :file_not_found}

      Map.has_key?(mediainfo_map, path) ->
        mediainfo_data = Map.get(mediainfo_map, path)
        mtime = Map.get(path_to_mtime, path)
        Cachex.put(@cache_name, path, {mediainfo_data, mtime})
        {:ok, mediainfo_data}

      true ->
        {:error, :mediainfo_failed}
    end
  end

  defp maybe_prune do
    case Cachex.size(@cache_name) do
      {:ok, size} when size > @max_cache_size -> Cachex.prune(@cache_name, @max_cache_size)
      _ -> :ok
    end
  end

  # Domain logic - mediainfo execution and parsing

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
        parse_batch_mediainfo_results(data, paths)

      {:ok, single_result} ->
        handle_single_mediainfo_result(single_result, paths)

      {:error, reason} ->
        {:error, {:json_decode, reason}}
    end
  end

  defp handle_single_mediainfo_result(single_result, paths) do
    if length(paths) == 1 do
      {:ok, %{List.first(paths) => single_result}}
    else
      {:error, {:unexpected_single_result, length(paths)}}
    end
  end

  defp parse_batch_mediainfo_results(media_info_list, original_paths) do
    if length(media_info_list) == length(original_paths) do
      parse_by_index_mapping(media_info_list, original_paths)
    else
      parse_by_path_extraction(media_info_list, original_paths)
    end
  end

  defp parse_by_index_mapping(media_info_list, original_paths) do
    result_map =
      original_paths
      |> Enum.zip(media_info_list)
      |> Map.new()

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
end
