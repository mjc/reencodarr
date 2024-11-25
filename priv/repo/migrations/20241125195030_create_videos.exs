defmodule Reencodarr.Repo.Migrations.CreateVideos do
  use Ecto.Migration

  def change do
    create table(:videos) do
      add :path, :string
      add :size, :integer
      add :bitrate, :integer

      timestamps(type: :utc_datetime)
    end
  end
end
