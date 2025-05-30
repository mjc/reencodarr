defmodule Reencodarr.Statistics.Stats do
  defstruct not_reencoded: 0,
            reencoded: 0,
            total_videos: 0,
            avg_vmaf_percentage: 0.0,
            total_vmafs: 0,
            chosen_vmafs_count: 0,
            lowest_vmaf: %Reencodarr.Media.Vmaf{},
            lowest_vmaf_by_time: %Reencodarr.Media.Vmaf{},
            most_recent_video_update: nil,
            most_recent_inserted_video: nil,
            queue_length: %{encodes: 0, crf_searches: 0},
            encode_queue_length: 0,
            next_crf_search: [],
            videos_by_estimated_percent: []
end
