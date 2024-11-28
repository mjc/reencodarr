defmodule Reencodarr.Repo.Migrations.AddAtmosBooleanToVideo do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      add :atmos, :boolean, default: false
    end
  end
end
