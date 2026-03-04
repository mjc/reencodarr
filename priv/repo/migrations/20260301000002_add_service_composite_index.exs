defmodule Reencodarr.Repo.Migrations.AddServiceCompositeIndex do
  use Ecto.Migration

  def change do
    # Composite index for service lookups during sync (upserts by service_id + service_type)
    create index(:videos, [:service_id, :service_type])
  end
end
