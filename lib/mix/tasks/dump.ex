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
    Task.async_stream(schemas, fn schema ->
      fields = schema.__schema__(:fields)
      file_name = "#{Atom.to_string(schema)}.csv"

      File.open(file_name, [:write, :utf8], fn file ->
        IO.write(file, Enum.join(fields, ",") <> "\n")

        Repo.transaction(fn ->
          Repo.stream(schema)
          |> Enum.each(fn record ->
            values = Enum.map(fields, fn field ->
              value = Map.get(record, field)
              value =
                cond do
                  is_binary(value) -> value
                  is_nil(value) -> ""
                  is_map(value) or is_list(value) ->
                    json = Jason.encode!(value)
                    if String.length(json) > 10_000 do
                      String.slice(json, 0, 10_000) <> "...(truncated)"
                    else
                      json
                    end
                  true -> inspect(value)
                end
              # CSV escaping: wrap in double quotes if contains comma, quote, or newline
              if String.contains?(value, [",", "\"", "\n"]) do
                "\"" <> String.replace(value, "\"", "\"\"") <> "\""
              else
                value
              end
            end)
            IO.write(file, Enum.join(values, ",") <> "\n")
          end)
        end)
      end)

      IO.puts("Dumped #{Atom.to_string(schema)} to #{file_name}")
    end, max_concurrency: System.schedulers_online())
  end
end
