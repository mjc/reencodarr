defmodule Reencodarr.Repo.Migrations.RemoveLegacyVideoBooleanColumns do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      remove :reencoded, :boolean, default: false
      remove :failed, :boolean, default: false
    end
  end
end
