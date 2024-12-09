defmodule Reencodarr.Repo.Migrations.MakeServicesUniqueForNow do
  use Ecto.Migration

  def change do
    create unique_index(:configs, [:service_type])
  end
end
