defmodule Mix.Tasks.Reencodarr.BackfillMediainfo do
  use Mix.Task

  @shortdoc "Backfills missing stored mediainfo without resetting video state"

  @moduledoc """
  Backfills missing stored MediaInfo for videos without resetting them for analysis.

      mix reencodarr.backfill_mediainfo
      mix reencodarr.backfill_mediainfo --batch-size 25 --sleep-ms 50
      mix reencodarr.backfill_mediainfo --batch-size 50 --max-concurrency 4
      mix reencodarr.backfill_mediainfo --limit 1000
  """

  @impl Mix.Task
  def run(args) do
    start_minimal_runtime()

    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [
          batch_size: :integer,
          max_concurrency: :integer,
          sleep_ms: :integer,
          limit: :integer
        ]
      )

    backfill_opts =
      opts
      |> Keyword.take([:batch_size, :max_concurrency, :sleep_ms, :limit])
      |> normalize_limit()

    {:ok, summary} = Reencodarr.Media.backfill_missing_mediainfo(backfill_opts)

    Mix.shell().info(
      "Backfill complete: scanned=#{summary.scanned} backfilled=#{summary.backfilled} failed=#{summary.failed}"
    )
  end

  defp start_minimal_runtime do
    Mix.Task.run("app.config")
    {:ok, _started_apps} = Application.ensure_all_started(:ecto_sql)
    {:ok, _repo_pid} = Reencodarr.Repo.start_link(pool_size: 1)
  end

  defp normalize_limit(opts) do
    case Keyword.fetch(opts, :limit) do
      {:ok, limit} when is_integer(limit) and limit > 0 ->
        opts

      {:ok, _invalid_limit} ->
        Keyword.delete(opts, :limit)

      :error ->
        opts
    end
  end
end
