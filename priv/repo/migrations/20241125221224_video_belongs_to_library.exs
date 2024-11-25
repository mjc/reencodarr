defmodule Reencodarr.Repo.Migrations.VideoBelongsToLibrary do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      add :library_id, references(:libraries, on_delete: :nothing)
    end
  end
end
