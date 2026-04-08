defmodule Reencodarr.Media.DashboardStatsCache do
  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema "dashboard_stats_cache" do
    field :total_videos, :integer
    field :total_size_bytes, :integer
    field :total_duration_seconds, :float
    field :duration_count, :integer
    field :needs_analysis, :integer
    field :analyzed, :integer
    field :crf_searching, :integer
    field :crf_searched, :integer
    field :encoding, :integer
    field :encoded, :integer
    field :failed, :integer
    field :most_recent_video_update, :utc_datetime
    field :most_recent_inserted_video, :utc_datetime
    field :total_vmafs, :integer
    field :chosen_vmafs, :integer
    field :encoding_queue_count, :integer
    field :encoded_savings_bytes, :integer
    field :predicted_savings_bytes, :integer
  end
end
