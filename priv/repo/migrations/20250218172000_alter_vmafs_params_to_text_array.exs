defmodule Reencodarr.Repo.Migrations.AlterVmafsParamsToTextArray do
  use Ecto.Migration

  def up do
    alter table(:vmafs) do
      modify :params, {:array, :text}, from: {:array, :string}
    end
  end

  def down do
    alter table(:vmafs) do
      modify :params, {:array, :string}, from: {:array, :text}
    end
  end
end
