defmodule Reencodarr.Repo.Migrations.ConvertTimeToSeconds do
  use Ecto.Migration

  def up do
    alter table(:vmafs) do
      add :duration, :integer
    end

    execute &convert_time_to_duration/0

    alter table(:vmafs) do
      remove :time
    end

    rename table(:vmafs), :duration, to: :time
  end

  defp convert_time_to_duration do
    execute """
    UPDATE vmafs
    SET duration =
      CASE
        WHEN time LIKE '% minutes' THEN CAST(SUBSTRING(time FROM '^[0-9]+') AS INTEGER) * 60
        WHEN time LIKE '% hours' THEN CAST(SUBSTRING(time FROM '^[0-9]+') AS INTEGER) * 3600
        WHEN time LIKE '% seconds' THEN CAST(SUBSTRING(time FROM '^[0-9]+') AS INTEGER)
        ELSE NULL
      END
    """
  end
end
