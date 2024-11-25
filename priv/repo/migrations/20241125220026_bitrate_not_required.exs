defmodule Reencodarr.Repo.Migrations.BitrateNotRequired do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      modify :bitrate, :integer, null: true
    end
  end
end
