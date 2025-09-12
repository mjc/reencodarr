defmodule Reencodarr.Statistics.Stats do
  @moduledoc """
  Statistics structure optimized for memory efficiency.

  Note: lowest_vmaf and lowest_vmaf_by_time store minimal data instead of full VMAF structs
  to reduce memory usage, since they're only used internally and not displayed in the UI.
  """

  @type t :: %__MODULE__{
          total_videos: integer() | nil,
          reencoded_count: integer() | nil,
          failed_count: integer() | nil,
          analyzing_count: integer() | nil,
          encoding_count: integer() | nil,
          searching_count: integer() | nil,
          available_count: integer() | nil,
          paused_count: integer() | nil,
          skipped_count: integer() | nil,
          avg_vmaf_percentage: float() | nil,
          total_savings_gb: float() | nil,
          total_vmafs: non_neg_integer(),
          chosen_vmafs_count: non_neg_integer(),
          lowest_vmaf_percent: float() | nil,
          lowest_vmaf_by_time_seconds: integer() | nil,
          most_recent_video_update: DateTime.t() | nil,
          most_recent_inserted_video: DateTime.t() | nil,
          queue_length: %{
            encodes: non_neg_integer(),
            crf_searches: non_neg_integer(),
            analyzer: non_neg_integer()
          },
          encode_queue_length: non_neg_integer(),
          next_crf_search: list(),
          videos_by_estimated_percent: list(),
          next_analyzer: list()
        }

  defstruct [
    :total_videos,
    :reencoded_count,
    :failed_count,
    :analyzing_count,
    :encoding_count,
    :searching_count,
    :available_count,
    :paused_count,
    :skipped_count,
    :avg_vmaf_percentage,
    :total_savings_gb,
    total_vmafs: 0,
    chosen_vmafs_count: 0,
    # Store minimal data instead of full VMAF structs - saves ~90% memory per VMAF
    lowest_vmaf_percent: nil,
    lowest_vmaf_by_time_seconds: nil,
    most_recent_video_update: nil,
    most_recent_inserted_video: nil,
    queue_length: %{encodes: 0, crf_searches: 0, analyzer: 0},
    encode_queue_length: 0,
    next_crf_search: [],
    videos_by_estimated_percent: [],
    next_analyzer: []
  ]
end
