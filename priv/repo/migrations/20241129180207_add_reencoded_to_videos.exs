defmodule Reencodarr.Repo.Migrations.AddReencodedToVideos do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      add :reencoded, :boolean, default: false, null: false
    end
  end
end
