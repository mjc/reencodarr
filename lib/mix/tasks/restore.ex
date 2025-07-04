defmodule Mix.Tasks.Restore do
  use Mix.Task

  @shortdoc "Restore the database from CSV dumps"

  @moduledoc """
  Restores all schemas from CSV files generated by the dump task.

      mix restore
  """

  alias Reencodarr.Repo

  def run(_args) do
    Mix.Task.run("app.start")

    {:ok, modules} = :application.get_key(:reencodarr, :modules)

    schemas =
      modules
      |> Enum.filter(&({:__schema__, 1} in &1.__info__(:functions)))

    Enum.each(schemas, &restore_schema/1)
  end

  # Restores a single schema from its CSV file
  defp restore_schema(schema) do
    file_name = "#{Atom.to_string(schema)}.csv"

    if File.exists?(file_name) do
      IO.puts("Restoring #{file_name} ...")

      [header | rows] =
        File.stream!(file_name, [], :line)
        |> Enum.map(&String.trim_trailing(&1, "\n"))

      fields = String.split(header, ",") |> Enum.map(&String.to_atom/1)
      Enum.each(rows, &process_csv_row(schema, &1, fields))
    end
  end

  # Processes a single CSV row: parses, validates, and inserts
  defp process_csv_row(schema, row, fields) do
    values = parse_csv_row(row)
    valid? = is_list(values) and length(values) == length(fields)

    if valid? do
      attrs =
        fields
        |> Enum.zip(values)
        |> Enum.into(%{}, fn {field, value} ->
          {field, parse_field(schema, field, value)}
        end)

      struct(schema, attrs)
      |> Repo.insert!()
    end
  end

  # Parses a CSV row into a list of values, handling quoted fields and escaped quotes
  defp parse_csv_row(row) do
    NimbleCSV.RFC4180.parse_string(row) |> List.first()
  end

  # Parse a field value based on schema type, return nil for empty string
  defp parse_field(_schema, _field, ""), do: nil

  defp parse_field(schema, field, value) do
    type = schema.__schema__(:type, field)

    parsed =
      case type do
        :map -> Jason.decode!(value)
        :array -> Jason.decode!(value)
        :integer -> String.to_integer(value)
        :float -> String.to_float(value)
        :boolean -> value in ["true", "1"]
        :naive_datetime -> NaiveDateTime.from_iso8601!(value)
        :utc_datetime -> DateTime.from_iso8601(value) |> elem(1)
        _ -> value
      end

    parsed
  rescue
    _ -> value
  end
end
