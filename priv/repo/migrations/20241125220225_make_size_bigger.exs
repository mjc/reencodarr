defmodule Reencodarr.Repo.Migrations.MakeSizeBigger do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      modify :size, :bigint
    end
  end
end
