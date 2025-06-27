defmodule ReencodarrWeb.Dashboard.Presenter do
  @moduledoc """
  Transforms raw dashboard state into presentation-ready data structures.
  This layer handles all data normalization and formatting logic.
  Optimized for memory efficiency by limiting data structures and using streams.
  """

  alias ReencodarrWeb.Utils.TimeUtils
  alias Reencodarr.Dashboard.QueueItem

  def present(dashboard_state, timezone \\ "UTC") do
    %{
      metrics: present_metrics(dashboard_state.stats),
      status: present_status(dashboard_state),
      queues: present_queues(dashboard_state),
      stats: present_stats(dashboard_state.stats, timezone)
    }
  end

  defp present_metrics(stats) do
    [
      %{
        title: "Total Videos",
        value: stats.total_videos,
        icon: "📹",
        color: "from-blue-500 to-cyan-500",
        subtitle: "in library"
      },
      %{
        title: "Reencoded",
        value: stats.reencoded,
        icon: "✨",
        color: "from-emerald-500 to-teal-500",
        subtitle: "optimized",
        progress: calculate_progress(stats.reencoded, stats.total_videos)
      },
      %{
        title: "VMAF Quality",
        value: "#{stats.avg_vmaf_percentage}%",
        icon: "🎯",
        color: "from-violet-500 to-purple-500",
        subtitle: "average"
      },
      %{
        title: "Queue Length",
        value: stats.queue_length.crf_searches + stats.queue_length.encodes,
        icon: "⏳",
        color: "from-amber-500 to-orange-500",
        subtitle: "pending jobs"
      }
    ]
  end

  defp present_status(dashboard_state) do
    %{
      encoding: %{
        active: dashboard_state.encoding,
        progress: normalize_progress(dashboard_state.encoding_progress)
      },
      crf_searching: %{
        active: dashboard_state.crf_searching,
        progress: normalize_progress(dashboard_state.crf_search_progress)
      },
      syncing: %{
        active: dashboard_state.syncing,
        progress: dashboard_state.sync_progress
      }
    }
  end

  defp present_queues(dashboard_state) do
    %{
      crf_search: %{
        title: "CRF Search Queue",
        icon: "🔍",
        color: "from-cyan-500 to-blue-500",
        files: normalize_queue_files(Reencodarr.DashboardState.crf_search_queue(dashboard_state))
      },
      encoding: %{
        title: "Encoding Queue",
        icon: "⚡",
        color: "from-emerald-500 to-teal-500",
        files: normalize_queue_files(Reencodarr.DashboardState.encoding_queue(dashboard_state))
      }
    }
  end

  defp present_stats(stats, _timezone) do
    %{
      total_vmafs: stats.total_vmafs,
      chosen_vmafs_count: stats.chosen_vmafs_count,
      last_video_update: TimeUtils.relative_time(stats.most_recent_video_update),
      last_video_insert: TimeUtils.relative_time(stats.most_recent_inserted_video)
    }
  end

  # Helper functions
  defp calculate_progress(completed, total) when total > 0 do
    (completed / total * 100) |> Float.round(1)
  end
  defp calculate_progress(_, _), do: 0

  defp normalize_progress(progress) when is_map(progress) and map_size(progress) > 0 do
    %{
      percent: Map.get(progress, :percent, 0),
      filename: normalize_filename(Map.get(progress, :filename))
    }
  end
  defp normalize_progress(_), do: nil

  defp normalize_filename(filename) when is_binary(filename), do: filename
  defp normalize_filename(:none), do: nil
  defp normalize_filename(_), do: nil

  defp normalize_queue_files(files) when is_list(files) do
    # Since DashboardState already limits to 10 items, we can process directly
    # Use more efficient Stream operations for better memory usage
    files
    |> Stream.with_index(1)  # Start index at 1
    |> Enum.map(fn {file, index} -> QueueItem.from_video(file, index) end)
  end
  defp normalize_queue_files(_), do: []

  @doc """
  Reports approximate memory usage of dashboard data for monitoring.
  Useful for tracking optimization effectiveness.
  """
  def memory_usage(dashboard_data) do
    queue_items_count =
      length(dashboard_data.queues.crf_search.files) +
      length(dashboard_data.queues.encoding.files)

    # Rough estimation - each queue item ~200 bytes, other data ~2KB
    estimated_bytes = (queue_items_count * 200) + 2048

    %{
      queue_items: queue_items_count,
      estimated_bytes: estimated_bytes,
      estimated_kb: Float.round(estimated_bytes / 1024, 2)
    }
  end
end
