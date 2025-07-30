defmodule Mix.Tasks.Reencodarr.FailureReport do
  use Mix.Task

  @moduledoc """
  Generates and displays a video processing failure report.

  ## Usage

      mix reencodarr.failure_report [options]

  ## Options

    * `--days` - Number of days to look back (default: 7)
    * `--limit` - Maximum number of common patterns to show (default: 10)
    * `--format` - Output format: console or json (default: console)

  ## Examples

      # Generate report for last 7 days
      mix reencodarr.failure_report

      # Generate report for last 14 days with top 20 patterns
      mix reencodarr.failure_report --days 14 --limit 20

      # Generate JSON report for external processing
      mix reencodarr.failure_report --format json
  """

  @shortdoc "Generates video processing failure report"

  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _errors} =
      OptionParser.parse(args,
        switches: [days: :integer, limit: :integer, format: :string],
        aliases: [d: :days, l: :limit, f: :format]
      )

    days_back = Keyword.get(opts, :days, 7)
    limit = Keyword.get(opts, :limit, 10)
    format = Keyword.get(opts, :format, "console")

    report_opts = [days_back: days_back, limit: limit]

    case format do
      "json" ->
        report = Reencodarr.FailureReporting.generate_failure_report(report_opts)
        IO.puts(Jason.encode!(report, pretty: true))

      "console" ->
        Reencodarr.FailureReporting.print_failure_report(report_opts)

      _ ->
        Mix.shell().error("Invalid format. Use 'console' or 'json'.")
        System.halt(1)
    end
  end
end
