defmodule Reencodarr.Repo.Migrations.AddFailureReportingIndexes do
  use Ecto.Migration

  def change do
    create index(
             :video_failures,
             [:inserted_at, :failure_stage, :failure_category, :resolved],
             name: "video_failures_stage_category_window_idx"
           )

    create index(
             :video_failures,
             [:resolved, :failure_stage, :failure_category, :failure_code, :inserted_at],
             name: "video_failures_common_patterns_idx"
           )

    create index(
             :video_failures,
             [:resolved, :inserted_at, :video_id],
             name: "video_failures_unresolved_recent_idx"
           )
  end
end
