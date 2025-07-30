defmodule Reencodarr.Repo.Migrations.CreateVideoFailures do
  use Ecto.Migration

  def change do
    create table(:video_failures) do
      add :video_id, references(:videos, on_delete: :delete_all), null: false
      add :failure_stage, :string, null: false
      add :failure_category, :string, null: false
      add :failure_code, :string
      add :failure_message, :text, null: false
      add :system_context, :map
      add :retry_count, :integer, default: 0
      add :resolved, :boolean, default: false
      add :resolved_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:video_failures, [:video_id])
    create index(:video_failures, [:failure_stage])
    create index(:video_failures, [:failure_category])
    create index(:video_failures, [:resolved])
    create index(:video_failures, [:inserted_at])

    # Add composite index for fast queries on active failures
    create index(:video_failures, [:video_id, :resolved])
  end
end
