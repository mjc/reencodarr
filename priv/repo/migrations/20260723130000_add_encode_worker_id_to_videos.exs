defmodule Reencodarr.Repo.Migrations.AddEncodeWorkerIdToVideos do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      add :encode_worker_id, :string
    end

    create index(:videos, [:state, :encode_worker_id])
  end
end
