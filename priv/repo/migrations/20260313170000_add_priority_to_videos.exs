defmodule Reencodarr.Repo.Migrations.AddPriorityToVideos do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      add :priority, :integer, default: 0, null: false
    end

    create index(:videos, [:state, :priority])
  end
end
