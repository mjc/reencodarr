defmodule Reencodarr.BadFiles.State do
  @moduledoc false

  alias Reencodarr.Media

  @active_statuses [:open, :queued, :processing, :waiting_for_replacement, :failed]
  @resolved_statuses [:replaced_clean, :dismissed]
  @resolved_limit 50

  @spec load(map()) :: map()
  def load(assigns) do
    {active_statuses, resolved_statuses} = statuses_for_filter(assigns.status_filter)
    {active_issues, meta} = fetch_active_issues(active_statuses, assigns)
    active_total = meta.total_count || 0
    issue_summary = Media.bad_file_issue_summary()
    resolved_issues = fetch_resolved_issues(assigns, resolved_statuses, assigns.show_resolved)
    issues = active_issues ++ resolved_issues

    %{
      issues: issues,
      meta: meta,
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

  def active_statuses_for_filter("all"), do: @active_statuses
  def active_statuses_for_filter("resolved"), do: []

  def active_statuses_for_filter(status_filter) do
    status = String.to_existing_atom(status_filter)

    if status in @active_statuses, do: [status], else: @active_statuses
  rescue
    ArgumentError -> @active_statuses
  end

  def list_active_issues(assigns, opts \\ []) do
    assigns
    |> Map.put(:page, Keyword.get(opts, :page, 1))
    |> Map.put(:per_page, Keyword.get(opts, :per_page, 250))
    |> list_issues(active_statuses_for_filter(assigns.status_filter))
    |> elem(0)
  end

  def flop_params(assigns) do
    %{
      "page" => to_string(assigns.page),
      "page_size" => to_string(assigns.per_page),
      "service" => assigns.service_filter,
      "kind" => assigns.kind_filter,
      "search" => assigns.search_query
    }
  end

  defp list_issues(assigns, active_statuses), do: fetch_active_issues(active_statuses, assigns)

  defp fetch_active_issues([], _assigns), do: {[], %Flop.Meta{}}

  defp fetch_active_issues(active_statuses, assigns) do
    Media.list_bad_file_issues(flop_params(assigns), statuses: active_statuses)
  end

  defp fetch_resolved_issues(_assigns, _resolved_statuses, false), do: []
  defp fetch_resolved_issues(_assigns, [], true), do: []

  defp fetch_resolved_issues(assigns, resolved_statuses, true) do
    {issues, _} =
      Media.list_bad_file_issues(
        assigns
        |> Map.put(:page, 1)
        |> Map.put(:per_page, @resolved_limit)
        |> flop_params(),
        statuses: resolved_statuses
      )

    issues
  end

  defp statuses_for_filter("all"), do: {@active_statuses, @resolved_statuses}
  defp statuses_for_filter("resolved"), do: {[], @resolved_statuses}

  defp statuses_for_filter(status_filter) do
    status = String.to_existing_atom(status_filter)

    cond do
      status in @active_statuses -> {[status], []}
      status in @resolved_statuses -> {[], [status]}
      true -> {@active_statuses, @resolved_statuses}
    end
  rescue
    ArgumentError -> {@active_statuses, @resolved_statuses}
  end
end
