defmodule Reencodarr.Repo.Migrations.AddChartQueryIndexes do
  use Ecto.Migration

  def change do
    # Index for vmaf_score_distribution query:
    # Joins vmaf to videos on chosen_vmaf_id, filters by score NOT NULL
    create index(:vmafs, [:score], where: "score IS NOT NULL", name: "vmafs_score_idx")

    # Composite index for vmaf score distribution (chosen VMAFs):
    # WHERE chosen_vmaf_id IS NOT NULL to find encoded videos
    create index(:videos, [:chosen_vmaf_id],
             where: "chosen_vmaf_id IS NOT NULL",
             name: "videos_chosen_vmaf_idx"
           )

    # Index for resolution_distribution query:
    # WHERE width IS NOT NULL AND state != :failed
    create index(
             :videos,
             [:width, :state],
             where: "width IS NOT NULL AND state != 'failed'",
             name: "videos_width_state_idx"
           )

    # Index for codec_distribution query:
    # WHERE video_codecs IS NOT NULL
    create index(:videos, [:video_codecs],
             where: "video_codecs IS NOT NULL",
             name: "videos_video_codecs_idx"
           )
  end
end
