defmodule Reencodarr.Repo.Migrations.AlterVmafsSizeType do
  use Ecto.Migration

  def up do
    alter table(:vmafs) do
      modify :size, :text
    end

    alter table(:videos) do
      modify :path, :text
    end
  end

  def down do
    alter table(:vmafs) do
      modify :size, :string
    end

    alter table(:videos) do
      modify :path, :string
    end
  end
end
