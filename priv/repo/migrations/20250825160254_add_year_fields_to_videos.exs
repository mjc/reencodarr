defmodule Reencodarr.Repo.Migrations.AddYearFieldsToVideos do
  use Ecto.Migration

  def change do
    alter table(:videos) do
      add :content_year, :integer,
        comment:
          "Content year: movie release year, TV series start year, or episode air year from API"
    end

    # Add index for efficient grain detection queries
    create index(:videos, [:content_year])
  end
end
