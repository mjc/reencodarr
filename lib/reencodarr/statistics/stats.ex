defmodule Reencodarr.Statistics.Stats do
  @moduledoc """
  Statistics structure optimized for memory efficiency.

  Note: lowest_vmaf and lowest_vmaf_by_time store minimal data instead of full VMAF structs
  to reduce memory usage, since they're only used internally and not displayed in the UI.
  """

  defstruct not_reencoded: 0,
            reencoded: 0,
            total_videos: 0,
            avg_vmaf_percentage: 0.0,
            total_vmafs: 0,
            chosen_vmafs_count: 0,
            # Store minimal data instead of full VMAF structs - saves ~90% memory per VMAF
            lowest_vmaf_percent: nil,
            lowest_vmaf_by_time_seconds: nil,
            most_recent_video_update: nil,
            most_recent_inserted_video: nil,
            queue_length: %{encodes: 0, crf_searches: 0},
            encode_queue_length: 0,
            next_crf_search: [],
            videos_by_estimated_percent: []
end
