defmodule Reencodarr.Repo.Migrations.CreateLibraries do
  use Ecto.Migration

  def change do
    create table(:libraries) do
      add :path, :string
      add :monitor, :boolean, default: false, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:libraries, [:path])
  end
end
