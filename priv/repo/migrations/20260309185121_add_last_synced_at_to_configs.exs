defmodule Reencodarr.Repo.Migrations.AddLastSyncedAtToConfigs do
  use Ecto.Migration

  def change do
    alter table(:configs) do
      add :last_synced_at, :utc_datetime
    end
  end
end
