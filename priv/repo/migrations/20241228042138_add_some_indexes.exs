defmodule Reencodarr.Repo.Migrations.AddSomeIndexes do
  use Ecto.Migration

  def change do
    create index(:vmafs, [:chosen])
  end
end
