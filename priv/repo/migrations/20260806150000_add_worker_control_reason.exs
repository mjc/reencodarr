defmodule Reencodarr.Repo.Migrations.AddWorkerControlReason do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      add :worker_control_reason, :string
    end
  end
end
