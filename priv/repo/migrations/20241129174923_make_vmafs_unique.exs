defmodule Reencodarr.Repo.Migrations.MakeVmafsUnique do
  use Ecto.Migration

  def change do
    create unique_index(:vmafs, [:crf, :video_id])
  end
end
