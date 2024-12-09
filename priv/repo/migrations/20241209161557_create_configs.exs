defmodule Reencodarr.Repo.Migrations.CreateConfigs do
  use Ecto.Migration

  def change do
    create table(:configs) do
      add :url, :string
      add :api_key, :string
      add :enabled, :boolean, default: false, null: false
      add :service_type, :string

      timestamps(type: :utc_datetime)
    end
  end
end
