defmodule Reencodarr.Repo.Migrations.AddSyncKnownFilesCoveringIndex do
  use Ecto.Migration

  def change do
    create index(:videos, [:service_type, :path, :service_id])
  end
end
