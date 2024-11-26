defmodule Reencodarr.Repo.Migrations.MakePathLonger do
  use Ecto.Migration

  def up do
    alter table(:videos) do
      modify :path, :text
    end
  end

  def down do
  end
end
