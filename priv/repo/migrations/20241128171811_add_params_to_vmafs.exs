defmodule Reencodarr.Repo.Migrations.AddParamsToVmafs do
  use Ecto.Migration

  def change do
    alter table(:vmafs) do
      add :params, {:array, :string}
    end
  end
end
