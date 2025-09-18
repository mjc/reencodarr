defmodule Reencodarr.Progress.Normalizer do
  @moduledoc """
  Normalizes progress data from different sources into a consistent format.

  This module handles the conversion of various progress types (encoding, CRF search,
  analyzer, sync) into a standardized format for the dashboard.
  """
  require Logger

  @doc """
  Normalizes encoding or CRF search progress data.
  """
  @spec normalize_progress(progress :: map() | nil) :: map()
  def normalize_progress(progress) when is_map(progress) do
    cond do
      has_analyzer_progress?(progress) -> build_progress_map(progress)
      has_crf_search_progress?(progress) -> build_progress_map(progress)
      has_basic_progress?(progress) -> build_progress_map(progress)
      true -> empty_progress()
    end
  end

  def normalize_progress(_progress) do
    empty_progress()
  end

  # Helper to check for analyzer progress
  defp has_analyzer_progress?(progress) do
    throughput = Map.get(progress, :throughput, 0)
    rate_limit = Map.get(progress, :rate_limit, 0)
    batch_size = Map.get(progress, :batch_size, 0)
    throughput > 0 or rate_limit > 0 or batch_size > 0
  end

  # Helper to check for CRF search progress
  defp has_crf_search_progress?(progress) do
    crf = Map.get(progress, :crf)
    score = Map.get(progress, :score)
    crf != nil or score != nil
  end

  # Helper to check for basic progress
  defp has_basic_progress?(progress) do
    filename = normalize_filename(Map.get(progress, :filename))
    percent = Map.get(progress, :percent, 0)

    case {percent, filename} do
      {p, _} when p > 0 -> true
      {_, f} when is_binary(f) -> true
      _ -> false
    end
  end

  defp build_progress_map(progress) do
    %{
      percent: Map.get(progress, :percent, 0),
      filename: Map.get(progress, :filename),
      fps: Map.get(progress, :fps, 0),
      eta: Map.get(progress, :eta, 0),
      crf: Map.get(progress, :crf),
      score: Map.get(progress, :score),
      throughput: Map.get(progress, :throughput, 0.0),
      rate_limit: Map.get(progress, :rate_limit, 0),
      batch_size: Map.get(progress, :batch_size, 0)
    }
  end

  @doc """
  Normalizes sync progress data with service type context.
  """
  @spec normalize_sync_progress(progress :: integer() | nil, service_type :: atom() | nil) ::
          map()
  def normalize_sync_progress(progress, service_type)
      when is_integer(progress) and progress > 0 do
    sync_label =
      case service_type do
        :sonarr -> "TV SYNC"
        :radarr -> "MOVIE SYNC"
        _ -> "LIBRARY SYNC"
      end

    %{
      percent: progress,
      filename: sync_label
    }
  end

  def normalize_sync_progress(_, _) do
    %{
      percent: 0,
      filename: nil
    }
  end

  # Returns an empty progress structure.
  @spec empty_progress() :: map()
  defp empty_progress do
    %{
      percent: 0,
      filename: nil,
      fps: 0,
      eta: 0,
      crf: nil,
      score: nil,
      throughput: 0.0
    }
  end

  # Normalizes filename values, handling different input types.
  @spec normalize_filename(filename :: any()) :: String.t() | nil
  defp normalize_filename(filename) when is_binary(filename), do: filename
  defp normalize_filename(:none), do: nil
  defp normalize_filename(_), do: nil
end
