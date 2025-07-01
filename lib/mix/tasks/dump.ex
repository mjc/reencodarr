defmodule Mix.Tasks.Dump do
  use Mix.Task

  @shortdoc "Dump the current state of the application"

  @moduledoc """
  Dumps the current state of the application to a file.

  ## Examples

      mix dump
  """

  alias Reencodarr.Repo

  @doc "Run the dump task asynchronously for all schemas."
  def run(_args) do
    Mix.Task.run("app.start")
    schemas = get_schemas()

    Task.async_stream(schemas, &dump_schema/1,
      max_concurrency: System.schedulers_online(),
      timeout: :infinity
    )
    |> Stream.run()
  end

  # Retrieves all Ecto schemas from the application modules
  defp get_schemas do
    {:ok, modules} = :application.get_key(:reencodarr, :modules)
    Enum.filter(modules, &({:__schema__, 1} in &1.__info__(:functions)))
  end

  # Dumps a single schema to CSV file with header and records
  defp dump_schema(schema) do
    file_name = "#{Atom.to_string(schema)}.csv"
    fields = schema.__schema__(:fields)

    File.open(file_name, [:write, :utf8], fn file ->
      IO.write(file, Enum.join(fields, ",") <> "\n")

      Repo.transaction(
        fn ->
          Repo.stream(schema, timeout: :infinity)
          |> Enum.each(&write_record_line(&1, fields, file))
        end,
        timeout: :infinity
      )
    end)

    IO.puts("Dumped #{Atom.to_string(schema)} to #{file_name}")
  end

  # Writes a single record line to the CSV file
  defp write_record_line(record, fields, file) do
    values = Enum.map(fields, &format_field_value(record, &1))
    IO.write(file, Enum.join(values, ",") <> "\n")
  end

  # Helper functions for CSV formatting
  defp format_field_value(record, field) do
    record
    |> Map.get(field)
    |> normalize_value()
    |> escape_csv_value()
  end

  defp normalize_value(value) do
    cond do
      is_binary(value) -> value
      is_nil(value) -> ""
      is_map(value) or is_list(value) -> Jason.encode!(value)
      true -> inspect(value)
    end
  end

  defp escape_csv_value(value) do
    if String.contains?(value, [",", "\"", "\n"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end
end
