defmodule Reencodarr.Repo.Migrations.AddWorkerControlRequestedAt do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      add :worker_control_requested_at, :utc_datetime_usec
    end

    execute(
      """
      UPDATE videos
      SET worker_control_requested_at = updated_at
      WHERE worker_control_desired_state = 'paused'
      """,
      """
      UPDATE videos
      SET worker_control_requested_at = NULL
      """
    )
  end
end
