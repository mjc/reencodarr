defmodule Mix.Tasks.Dump do
  use Mix.Task

  @shortdoc "Dump the current state of the application"

  @moduledoc """
  Dumps the current state of the application to a file.

  ## Examples

      mix dump
  """

  alias Reencodarr.Repo

  def run(_args) do
    Mix.Task.run("app.start")

    # get a list of all the schemas in the application

    {:ok, modules} = :application.get_key(:reencodarr, :modules)

    schemas =
      modules
      |> Enum.filter(&({:__schema__, 1} in &1.__info__(:functions)))

    # dump each schema to a csv file with header
    Task.async_stream(
      schemas,
      fn schema ->
        fields = schema.__schema__(:fields)
        file_name = "#{Atom.to_string(schema)}.csv"

        File.open(file_name, [:write, :utf8], fn file ->
          IO.write(file, Enum.join(fields, ",") <> "\n")

          Repo.transaction(
            fn ->
              Repo.stream(schema, timeout: :infinity)
              |> Enum.each(fn record ->
                values = Enum.map(fields, &format_field_value(record, &1))
                IO.write(file, Enum.join(values, ",") <> "\n")
              end)
            end,
            timeout: :infinity
          )
        end)

        IO.puts("Dumped #{Atom.to_string(schema)} to #{file_name}")
      end,
      max_concurrency: System.schedulers_online(),
      timeout: :infinity
    )
    |> Stream.run()
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
