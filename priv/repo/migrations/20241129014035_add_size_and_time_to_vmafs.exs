defmodule Reencodarr.Repo.Migrations.AddSizeAndTimeToVmafs do
  use Ecto.Migration

  def change do
    alter table(:vmafs) do
      add :size, :string
      add :time, :string
    end
  end
end
