defmodule Reencodarr.Repo.Migrations.AddTargetToVmafs do
  use Ecto.Migration

  def change do
    alter table(:vmafs) do
      add :target, :integer
    end
  end
end
