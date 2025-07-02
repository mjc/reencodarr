defmodule Reencodarr.Progress.Normalizer do
  @moduledoc """
  Normalizes progress data from different sources into a consistent format.

  This module handles the conversion of various progress types (encoding, CRF search,
  analyzer, sync) into a standardized format for the dashboard.
  """

  @doc """
  Normalizes encoding or CRF search progress data.
  """
  @spec normalize_progress(progress :: map() | nil) :: map()
  def normalize_progress(progress) when is_map(progress) do
    filename = normalize_filename(Map.get(progress, :filename))
    percent = Map.get(progress, :percent, 0)
    # Only get these fields if they exist (encoding/CRF search have them, sync doesn't)
    fps = Map.get(progress, :fps, 0)
    eta = Map.get(progress, :eta, 0)
    # CRF search specific fields
    crf = Map.get(progress, :crf)
    score = Map.get(progress, :score)

    # Show progress if we have either a meaningful percent or filename
    if percent > 0 or filename do
      %{
        percent: percent,
        filename: filename,
        fps: fps,
        eta: eta,
        crf: crf,
        score: score
      }
    else
      empty_progress()
    end
  end

  def normalize_progress(_), do: empty_progress()

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
      score: nil
    }
  end

  # Normalizes filename values, handling different input types.
  @spec normalize_filename(filename :: any()) :: String.t() | nil
  defp normalize_filename(filename) when is_binary(filename), do: filename
  defp normalize_filename(:none), do: nil
  defp normalize_filename(_), do: nil
end
