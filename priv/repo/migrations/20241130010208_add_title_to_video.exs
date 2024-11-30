defmodule Reencodarr.Repo.Migrations.AddTitleToVideo do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      add :title, :string
    end
  end
end
