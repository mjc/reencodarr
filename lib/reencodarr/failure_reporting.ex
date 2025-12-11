defmodule Reencodarr.FailureReporting do
  alias Reencodarr.Media
  alias Reencodarr.Media.VideoFailure

  @moduledoc """
  Provides reporting and analysis functions for video processing failures.

  Generates insights and reports to help with troubleshooting and
  improving the video processing pipeline.
  """

  @doc """
  Generates a comprehensive failure report for monitoring and investigation.

  ## Options

  * `:days_back` - Number of days to look back (default: 7)
  * `:limit` - Maximum number of common patterns to return (default: 10)
  """
  def generate_failure_report(opts \\ []) do
    days_back = Keyword.get(opts, :days_back, 7)
    limit = Keyword.get(opts, :limit, 10)

    %{
      summary: get_failure_summary(days_back),
      by_stage: get_failures_by_stage(days_back),
      by_category: get_failures_by_category(days_back),
      common_patterns: Media.get_common_failure_patterns(limit),
      recent_failures: get_recent_failures(20),
      resolution_rate: get_resolution_rate(days_back),
      recommendations: generate_recommendations(days_back)
    }
  end

  @doc """
  Gets a quick summary of failure statistics.
  """
  def get_failure_summary(days_back \\ 7) do
    cutoff_date = DateTime.utc_now() |> DateTime.add(-days_back * 24 * 60 * 60, :second)

    import Ecto.Query

    # Get total counts
    total_query =
      from(f in VideoFailure,
        where: f.inserted_at >= ^cutoff_date,
        select: %{
          total: count(f.id),
          resolved: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", f.resolved)),
          unresolved: sum(fragment("CASE WHEN NOT ? THEN 1 ELSE 0 END", f.resolved))
        }
      )

    stats = Reencodarr.Repo.one(total_query) || %{total: 0, resolved: 0, unresolved: 0}

    # Handle potential nil values from aggregate functions
    total = stats.total || 0
    resolved = stats.resolved || 0
    unresolved = stats.unresolved || 0

    resolution_rate = Reencodarr.Formatters.percentage(resolved, total)

    %{
      total_failures: total,
      resolved_failures: resolved,
      unresolved_failures: unresolved,
      resolution_rate_percent: resolution_rate,
      period_days: days_back
    }
  end

  @doc """
  Gets failure counts grouped by processing stage.
  """
  def get_failures_by_stage(days_back \\ 7) do
    stats = Media.get_failure_statistics(days_back: days_back)

    stats
    |> Enum.group_by(& &1.stage)
    |> Enum.map(fn {stage, stage_failures} ->
      total = Enum.sum(Enum.map(stage_failures, & &1.count))
      resolved = Enum.sum(Enum.map(stage_failures, & &1.resolved_count))

      %{
        stage: stage,
        total_count: total,
        resolved_count: resolved,
        unresolved_count: total - resolved,
        categories:
          Enum.map(stage_failures, fn f ->
            %{
              category: f.category,
              count: f.count,
              resolved_count: f.resolved_count
            }
          end)
      }
    end)
    |> Enum.sort_by(& &1.total_count, :desc)
  end

  @doc """
  Gets failure counts grouped by category across all stages.
  """
  def get_failures_by_category(days_back \\ 7) do
    stats = Media.get_failure_statistics(days_back: days_back)

    stats
    |> Enum.group_by(& &1.category)
    |> Enum.map(fn {category, category_failures} ->
      total = Enum.sum(Enum.map(category_failures, & &1.count))
      resolved = Enum.sum(Enum.map(category_failures, & &1.resolved_count))

      %{
        category: category,
        total_count: total,
        resolved_count: resolved,
        unresolved_count: total - resolved,
        stages:
          Enum.map(category_failures, fn f ->
            %{
              stage: f.stage,
              count: f.count,
              resolved_count: f.resolved_count
            }
          end)
      }
    end)
    |> Enum.sort_by(& &1.total_count, :desc)
  end

  @doc """
  Gets recent failure details for investigation.
  """
  def get_recent_failures(limit \\ 20) do
    import Ecto.Query

    query =
      from(f in VideoFailure,
        join: v in assoc(f, :video),
        where: f.resolved == false,
        order_by: [desc: f.inserted_at],
        limit: ^limit,
        select: %{
          id: f.id,
          video_id: f.video_id,
          video_path: v.path,
          stage: f.failure_stage,
          category: f.failure_category,
          code: f.failure_code,
          message: f.failure_message,
          retry_count: f.retry_count,
          occurred_at: f.inserted_at,
          context: f.system_context
        }
      )

    Reencodarr.Repo.all(query)
  end

  @doc """
  Gets overall resolution rate for failures.
  """
  def get_resolution_rate(days_back \\ 7) do
    summary = get_failure_summary(days_back)

    if summary.total_failures > 0 do
      summary.resolution_rate_percent
    else
      nil
    end
  end

  @doc """
  Generates actionable recommendations based on failure patterns.
  """
  def generate_recommendations(days_back \\ 7) do
    by_stage = get_failures_by_stage(days_back)
    by_category = get_failures_by_category(days_back)

    recommendations = []

    # Check for high failure stages
    recommendations = check_high_failure_stages(by_stage, recommendations)

    # Check for problematic categories
    recommendations = check_problematic_categories(by_category, recommendations)

    # Check for system issues
    recommendations = check_system_issues(by_category, recommendations)

    recommendations
  end

  # Helper function to check for stages with high failure rates
  defp check_high_failure_stages(by_stage, recommendations) do
    high_failure_stages =
      Enum.filter(by_stage, fn stage ->
        stage.total_count > 10 and stage.unresolved_count / stage.total_count > 0.7
      end)

    case high_failure_stages do
      [] ->
        recommendations

      stages ->
        stage_names = Enum.map_join(stages, ", ", & &1.stage)

        recommendation = %{
          priority: :high,
          category: :stage_failures,
          title: "High Failure Rate in Processing Stages",
          description: "Stages #{stage_names} have high failure rates (>70% unresolved)",
          action:
            "Investigate system resources, configuration, or input file quality for these stages"
        }

        [recommendation | recommendations]
    end
  end

  # Helper function to check for problematic categories
  defp check_problematic_categories(by_category, recommendations) do
    problematic =
      Enum.filter(by_category, fn cat ->
        cat.total_count > 5 and
          cat.category in [:resource_exhaustion, :system_environment, :file_operations]
      end)

    case problematic do
      [] ->
        recommendations

      categories ->
        cat_names = Enum.map_join(categories, ", ", & &1.category)

        recommendation = %{
          priority: :medium,
          category: :system_issues,
          title: "System-Related Failures Detected",
          description: "Categories #{cat_names} indicate potential system issues",
          action: "Check disk space, memory usage, file permissions, and system dependencies"
        }

        [recommendation | recommendations]
    end
  end

  # Helper function to check for system issues
  defp check_system_issues(by_category, recommendations) do
    resource_issues = Enum.find(by_category, &(&1.category == :resource_exhaustion))

    if resource_issues && resource_issues.total_count > 3 do
      recommendation = %{
        priority: :high,
        category: :resource_exhaustion,
        title: "Resource Exhaustion Issues",
        description:
          "Multiple resource exhaustion failures detected (#{resource_issues.total_count} occurrences)",
        action:
          "Monitor system resources (CPU, memory, disk) and consider scaling or optimization"
      }

      [recommendation | recommendations]
    else
      recommendations
    end
  end

  @doc """
  Prints a formatted failure report to the console.
  """
  def print_failure_report(opts \\ []) do
    report = generate_failure_report(opts)

    IO.puts(
      "\n" <> IO.ANSI.bright() <> "=== Video Processing Failure Report ===" <> IO.ANSI.reset()
    )

    IO.puts("Period: Last #{report.summary.period_days} days")
    IO.puts("")

    # Summary
    IO.puts(IO.ANSI.bright() <> "Summary:" <> IO.ANSI.reset())
    IO.puts("  Total Failures: #{report.summary.total_failures}")
    IO.puts("  Resolved: #{report.summary.resolved_failures}")
    IO.puts("  Unresolved: #{report.summary.unresolved_failures}")
    IO.puts("  Resolution Rate: #{report.summary.resolution_rate_percent}%")
    IO.puts("")

    # By Stage
    if not Enum.empty?(report.by_stage) do
      IO.puts(IO.ANSI.bright() <> "Failures by Stage:" <> IO.ANSI.reset())

      Enum.each(report.by_stage, fn stage ->
        IO.puts(
          "  #{stage.stage}: #{stage.total_count} total (#{stage.unresolved_count} unresolved)"
        )
      end)

      IO.puts("")
    end

    # Common Patterns
    print_common_patterns(report.common_patterns)
    print_recommendations(report.recommendations)
  end

  defp print_common_patterns([]), do: :ok

  defp print_common_patterns(patterns) do
    IO.puts(IO.ANSI.bright() <> "Most Common Failure Patterns:" <> IO.ANSI.reset())

    Enum.each(patterns, fn pattern ->
      IO.puts(
        "  #{pattern.stage}/#{pattern.category} (#{pattern.code}): #{pattern.count} occurrences"
      )

      if pattern.sample_message do
        IO.puts("    Sample: #{String.slice(pattern.sample_message, 0, 80)}...")
      end
    end)

    IO.puts("")
  end

  defp print_recommendations([]), do: :ok

  defp print_recommendations(recommendations) do
    IO.puts(IO.ANSI.bright() <> "Recommendations:" <> IO.ANSI.reset())

    Enum.each(recommendations, fn rec ->
      priority_color =
        case rec.priority do
          :high -> IO.ANSI.red()
          :medium -> IO.ANSI.yellow()
          :low -> IO.ANSI.green()
        end

      IO.puts(
        "  #{priority_color}[#{String.upcase(to_string(rec.priority))}]#{IO.ANSI.reset()} #{rec.title}"
      )

      IO.puts("    #{rec.description}")
      IO.puts("    Action: #{rec.action}")
      IO.puts("")
    end)
  end

  @doc """
  Get a quick overview of current active failures.
  """
  def get_failure_overview(opts \\ []) do
    days_back = Keyword.get(opts, :days_back, 1)

    summary = get_failure_summary(days_back)
    by_stage = get_failures_by_stage(days_back)

    %{
      total_failures: summary.total_failures,
      unresolved_failures: summary.unresolved_failures,
      stages_affected: length(by_stage),
      most_recent: get_recent_failures(limit: 5, days_back: days_back),
      requires_attention: summary.unresolved_failures > 0
    }
  end

  @doc """
  Check for critical failures that require immediate attention.

  Returns failures that indicate system-level issues or high-impact problems.
  """
  def get_critical_failures(opts \\ []) do
    days_back = Keyword.get(opts, :days_back, 1)
    cutoff_date = DateTime.utc_now() |> DateTime.add(-days_back * 24 * 60 * 60, :second)

    import Ecto.Query
    alias Reencodarr.Repo

    critical_categories = [:resource_exhaustion, :system_environment, :timeout]
    critical_codes = ["EXIT_137", "EXIT_143", "TIMEOUT", "RESOURCE_MEMORY", "ENV"]

    from(f in VideoFailure,
      where: f.inserted_at >= ^cutoff_date,
      where: not f.resolved,
      where: f.failure_category in ^critical_categories or f.failure_code in ^critical_codes,
      order_by: [desc: f.inserted_at],
      preload: [:video]
    )
    |> Repo.all()
    |> Enum.map(fn failure ->
      %{
        id: failure.id,
        video_id: failure.video_id,
        video_path: failure.video.path,
        stage: failure.failure_stage,
        category: failure.failure_category,
        code: failure.failure_code,
        message: failure.failure_message,
        occurred_at: failure.inserted_at,
        severity: classify_severity(failure.failure_category, failure.failure_code)
      }
    end)
  end

  defp classify_severity(category, code) do
    case {category, code} do
      {:resource_exhaustion, _} -> :high
      {:system_environment, _} -> :high
      {:timeout, _} -> :medium
      # OOM
      {_, "EXIT_137"} -> :high
      # SIGTERM
      {_, "EXIT_143"} -> :high
      _ -> :low
    end
  end
end
