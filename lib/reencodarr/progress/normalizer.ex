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
    # Check if this is an analyzer progress struct with throughput data
    throughput = Map.get(progress, :throughput, 0)
    rate_limit = Map.get(progress, :rate_limit, 0)
    batch_size = Map.get(progress, :batch_size, 0)

    # Show analyzer progress if we have performance data
    if throughput > 0 or rate_limit > 0 or batch_size > 0 do
      build_progress_map(progress)
    else
      filename = normalize_filename(Map.get(progress, :filename))
      percent = Map.get(progress, :percent, 0)

      # Show progress if we have either a meaningful percent or filename
      case {percent, filename} do
        {p, _} when p > 0 ->
          build_progress_map(progress)

        {_, f} when is_binary(f) ->
          build_progress_map(progress)

        _ ->
          empty_progress()
      end
    end
  end

  def normalize_progress(_progress) do
    empty_progress()
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
