defmodule Reencodarr.Repo.Migrations.AddFailedStatusToVideos do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      add :failed, :boolean, default: false, null: false
    end
  end
end
