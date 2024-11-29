defmodule Reencodarr.Repo.Migrations.AddChosenToVmafs do
  use Ecto.Migration

  def change do
    alter table(:vmafs) do
      add :chosen, :boolean, default: false, null: false
    end
  end
end
