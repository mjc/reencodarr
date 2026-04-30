defmodule Reencodarr.Release do
  @moduledoc false

  @app :reencodarr

  alias Reencodarr.Repo

  def migrate do
    load_app()
    ensure_database_directory!()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          Ecto.Migrator.run(repo, :up, all: true)
        end)
    end
  end

  defp load_app do
    Application.load(@app)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp ensure_database_directory! do
    case Application.fetch_env(@app, Repo) do
      {:ok, opts} ->
        opts
        |> Keyword.get(:database)
        |> maybe_create_parent_dir!()

      :error ->
        :ok
    end
  end

  defp maybe_create_parent_dir!(nil), do: :ok

  defp maybe_create_parent_dir!(database_path) do
    database_path
    |> Path.dirname()
    |> File.mkdir_p!()
  end
end
