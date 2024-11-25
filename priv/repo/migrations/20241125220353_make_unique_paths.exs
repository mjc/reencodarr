defmodule Reencodarr.Repo.Migrations.MakeUniquePaths do
  use Ecto.Migration

  def change do
    create unique_index(:videos, [:path])
  end
end
