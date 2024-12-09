defmodule Reencodarr.Repo.Migrations.AddServiceIdAndServiceTypeToVideos do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      add :service_id, :string
      add :service_type, :string
    end
  end
end
