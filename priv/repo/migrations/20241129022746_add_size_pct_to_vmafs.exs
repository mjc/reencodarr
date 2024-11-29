defmodule Reencodarr.Repo.Migrations.AddSizePctToVmafs do
  use Ecto.Migration

  def change do
    alter table(:vmafs) do
      add :percent, :float
    end
  end
end
