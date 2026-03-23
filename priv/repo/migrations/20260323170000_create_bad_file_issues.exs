defmodule Reencodarr.Repo.Migrations.CreateBadFileIssues do
  use Ecto.Migration

  def change do
    create table(:bad_file_issues) do
      add :video_id, references(:videos, on_delete: :delete_all), null: false
      add :origin, :string, null: false
      add :issue_kind, :string, null: false
      add :classification, :string, null: false
      add :status, :string, null: false, default: "open"
      add :manual_reason, :string
      add :manual_note, :text
      add :source_audio_codec, :string
      add :source_channels, :integer
      add :source_layout, :string
      add :output_audio_codec, :string
      add :output_channels, :integer
      add :output_layout, :string
      add :details, :map
      add :arr_command_ids, :map
      add :last_attempted_at, :utc_datetime
      add :resolved_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:bad_file_issues, [:video_id])
    create index(:bad_file_issues, [:status, :updated_at])
    create index(:bad_file_issues, [:video_id, :issue_kind, :classification])
  end
end
