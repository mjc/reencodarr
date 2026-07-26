defmodule Reencodarr.Repo.Migrations.AddWorkerControlStateToVideos do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      add :worker_control_desired_state, :string
      add :worker_control_acknowledged_state, :string
      add :worker_control_command_id, :string
    end

    execute(
      """
      UPDATE videos
      SET worker_control_desired_state = 'running',
          worker_control_acknowledged_state = 'running'
      WHERE state IN ('crf_searching', 'encoding')
        AND worker_attempt_id IS NOT NULL
      """,
      """
      UPDATE videos
      SET worker_control_desired_state = NULL,
          worker_control_acknowledged_state = NULL,
          worker_control_command_id = NULL
      """
    )

    create index(:videos, [:worker_attempt_id, :worker_control_command_id])
  end
end
