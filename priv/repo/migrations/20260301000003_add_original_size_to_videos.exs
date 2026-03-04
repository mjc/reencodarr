defmodule Reencodarr.Repo.Migrations.AddOriginalSizeToVideos do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      add :original_size, :integer
    end
  end
end
