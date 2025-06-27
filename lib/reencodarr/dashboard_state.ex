defmodule Reencodarr.DashboardState do
  @moduledoc """
  Defines the dashboard state structure and provides functions for state management.

  This module centralizes the state structure used across the dashboard and telemetry
  reporter, making it easier to maintain and understand state transitions.
  """

  alias Reencodarr.Statistics.{Stats, EncodingProgress, CrfSearchProgress}

  @type t :: %__MODULE__{
          stats: Stats.t(),
          encoding: boolean(),
          crf_searching: boolean(),
          syncing: boolean(),
          encoding_progress: EncodingProgress.t(),
          crf_search_progress: CrfSearchProgress.t(),
          sync_progress: non_neg_integer(),
          stats_update_in_progress: boolean(),
          videos_by_estimated_percent: list(),
          next_crf_search: list()
        }

  defstruct stats: %Stats{},
            encoding: false,
            crf_searching: false,
            syncing: false,
            encoding_progress: %EncodingProgress{},
            crf_search_progress: %CrfSearchProgress{},
            sync_progress: 0,
            stats_update_in_progress: false,
            videos_by_estimated_percent: [],
            next_crf_search: []

  @doc """
  Creates a new initial dashboard state.
  """
  def initial() do
    %__MODULE__{}
  end

  @doc """
  Returns just the progress-related state for performance optimization.
  """
  def progress_state(%__MODULE__{} = state) do
    %{
      encoding: state.encoding,
      crf_searching: state.crf_searching,
      syncing: state.syncing,
      encoding_progress: state.encoding_progress,
      crf_search_progress: state.crf_search_progress,
      sync_progress: state.sync_progress
    }
  end

  @doc """
  Updates the state with new statistics.
  """
  def update_stats(%__MODULE__{} = state, stats) do
    %{
      state
      | stats: stats,
        stats_update_in_progress: false,
        next_crf_search: stats.next_crf_search,
        videos_by_estimated_percent: stats.videos_by_estimated_percent
    }
  end

  @doc """
  Updates the state with new statistics, limiting queue data to reduce memory usage.
  """
  def update_stats_optimized(%__MODULE__{} = state, stats) do
    # Only store the queue items we'll actually display (first 10 each)
    # This can reduce memory usage by 90%+ for large queues
    limited_next_crf_search = Enum.take(stats.next_crf_search, 10)
    limited_videos_by_estimated_percent = Enum.take(stats.videos_by_estimated_percent, 10)

    # Store full counts but limited queue data
    optimized_stats = %{
      stats
      | next_crf_search: limited_next_crf_search,
        videos_by_estimated_percent: limited_videos_by_estimated_percent
    }

    %{
      state
      | stats: optimized_stats,
        stats_update_in_progress: false,
        next_crf_search: limited_next_crf_search,
        videos_by_estimated_percent: limited_videos_by_estimated_percent
    }
  end

  @doc """
  Updates encoding status and progress.
  """
  def update_encoding(%__MODULE__{} = state, status, filename \\ nil) do
    progress =
      if status do
        %EncodingProgress{filename: filename}
      else
        %EncodingProgress{}
      end

    %{state | encoding: status, encoding_progress: progress}
  end

  @doc """
  Updates CRF search status and optionally resets progress.
  """
  def update_crf_search(%__MODULE__{} = state, status) do
    # When starting a new search, reset progress. When stopping, preserve last values
    new_progress =
      if status do
        %CrfSearchProgress{}
      else
        state.crf_search_progress
      end

    %{state | crf_searching: status, crf_search_progress: new_progress}
  end

  @doc """
  Updates sync status and progress.
  """
  def update_sync(%__MODULE__{} = state, event, data \\ %{}) do
    case event do
      :started -> %{state | syncing: true, sync_progress: 0}
      :progress -> %{state | sync_progress: Map.get(data, :progress, 0)}
      :completed -> %{state | syncing: false, sync_progress: 0}
    end
  end

  @doc """
  Marks stats update as in progress or completed.
  """
  def set_stats_updating(%__MODULE__{} = state, updating) do
    %{state | stats_update_in_progress: updating}
  end
end
