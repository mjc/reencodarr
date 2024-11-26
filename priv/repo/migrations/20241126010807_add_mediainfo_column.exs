defmodule Reencodarr.Repo.Migrations.AddMediainfoColumn do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      add :mediainfo, :map
    end
  end
end
