defmodule Reencodarr.Repo.Migrations.AddCrfSearchWorkerIdToVideos do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      add :crf_search_worker_id, :string
    end

    create index(:videos, [:state, :crf_search_worker_id])
  end
end
