defmodule Mix.Tasks.Reencodarr.AudioAudit do
  @moduledoc """
  Audits pre-fix multichannel Opus outputs and writes findings to the bad_file_issues table.

  ## Examples

      mix reencodarr.audio_audit
      mix reencodarr.audio_audit --before 2026-02-14T02:46:11Z
  """

  use Mix.Task

  @shortdoc "Audits pre-fix multichannel Opus outputs into bad_file_issues"

  def run(args) do
    start_minimal_runtime()

    {opts, _argv, _errors} =
      OptionParser.parse(args,
        switches: [before: :string],
        aliases: [b: :before]
      )

    before =
      case Keyword.get(opts, :before) do
        nil ->
          nil

        value ->
          case DateTime.from_iso8601(value) do
            {:ok, datetime, _offset} ->
              datetime

            {:error, reason} ->
              Mix.raise("Invalid --before value #{inspect(value)}: #{inspect(reason)}")
          end
      end

    audit_opts =
      case before do
        nil -> []
        datetime -> [before: datetime]
      end

    {:ok, summary} = Reencodarr.Media.audit_pre_fix_multichannel_opus(audit_opts)

    Mix.shell().info("Scanned #{summary.scanned} candidate videos")
    Mix.shell().info("Upserted #{summary.issues_upserted} bad-file issues")
  end

  defp start_minimal_runtime do
    Mix.Task.run("app.config")
    {:ok, _started_apps} = Application.ensure_all_started(:ecto_sql)
    {:ok, _repo_pid} = Reencodarr.Repo.start_link(pool_size: 1)
  end
end
