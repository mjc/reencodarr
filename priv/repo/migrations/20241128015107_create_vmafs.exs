defmodule Reencodarr.Repo.Migrations.CreateVmafs do
  use Ecto.Migration

  def change do
    create table(:vmafs) do
      add :score, :float
      add :crf, :float
      add :video_id, references(:videos, on_delete: :nothing)

      timestamps(type: :utc_datetime)
    end

    create index(:vmafs, [:video_id])
  end
end
