defmodule Reencodarr.BadFiles.State do
  @moduledoc false

  alias Reencodarr.Media

  @active_statuses [:open, :queued, :processing, :waiting_for_replacement, :failed]
  @resolved_statuses [:replaced_clean, :dismissed]
  @resolved_limit 50

  @spec load(map()) :: map()
  def load(assigns) do
    filters = [
      service: assigns.service_filter,
      kind: assigns.kind_filter,
      search: assigns.search_query
    ]

    {active_statuses, resolved_statuses} = statuses_for_filter(assigns.status_filter)
    active_issues = fetch_active_issues(filters, active_statuses, assigns)
    active_total = fetch_active_total(filters, active_statuses)
    issue_summary = Media.bad_file_issue_summary()
    resolved_issues = fetch_resolved_issues(filters, resolved_statuses, assigns.show_resolved)
    issues = active_issues ++ resolved_issues

    %{
      issues: issues,
      tracked_count:
        issue_summary.open + issue_summary.queued + issue_summary.processing +
          issue_summary.waiting_for_replacement + issue_summary.failed + issue_summary.resolved,
      active_total: active_total,
      active_issues: active_issues,
      replacement_issues:
        Enum.filter(active_issues, &(&1.status in [:processing, :waiting_for_replacement])),
      resolved_issues: resolved_issues,
      issue_summary: issue_summary
    }
  end

  defp fetch_active_issues(_filters, [], _assigns), do: []

  defp fetch_active_issues(filters, active_statuses, assigns) do
    Media.list_bad_file_issues(
      filters ++
        [
          statuses: active_statuses,
          limit: assigns.per_page,
          offset: (assigns.page - 1) * assigns.per_page
        ]
    )
  end

  defp fetch_active_total(_filters, []), do: 0

  defp fetch_active_total(filters, active_statuses) do
    Media.count_bad_file_issues(filters ++ [statuses: active_statuses])
  end

  defp fetch_resolved_issues(_filters, _resolved_statuses, false), do: []
  defp fetch_resolved_issues(_filters, [], true), do: []

  defp fetch_resolved_issues(filters, resolved_statuses, true) do
    Media.list_bad_file_issues(filters ++ [statuses: resolved_statuses, limit: @resolved_limit])
  end

  defp statuses_for_filter(status_filter) do
    case status_filter do
      "all" ->
        {@active_statuses, @resolved_statuses}

      "resolved" ->
        {[], @resolved_statuses}

      other ->
        status = String.to_existing_atom(other)

        if status in @resolved_statuses do
          {[], [status]}
        else
          {[status], []}
        end
    end
  rescue
    ArgumentError -> {@active_statuses, @resolved_statuses}
  end
end
