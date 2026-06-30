defmodule Reencodarr.BadFiles.State do
  @moduledoc false

  alias Reencodarr.Media

  @active_statuses [:open, :queued, :processing, :waiting_for_replacement, :failed]
  @resolved_statuses [:replaced_clean, :dismissed]
  @active_status_filters Map.new(@active_statuses, &{Atom.to_string(&1), &1})
  @resolved_status_filters Map.new(@resolved_statuses, &{Atom.to_string(&1), &1})
  @replacement_statuses [:processing, :waiting_for_replacement]

  @spec load(map()) :: map()
  def load(assigns) do
    {active_statuses, resolved_statuses} = statuses_for_filter(assigns.status_filter)
    {active_issues, meta} = fetch_active_issues(active_statuses, assigns)
    issue_summary = Media.bad_file_issue_summary()

    resolved_issues =
      fetch_resolved_issues(assigns, resolved_statuses, show_resolved_issues?(assigns))

    issues = active_issues ++ resolved_issues

    %{
      issues: issues,
      meta: meta,
      tracked_count:
        issue_summary.open + issue_summary.queued + issue_summary.processing +
          issue_summary.waiting_for_replacement + issue_summary.failed + issue_summary.resolved,
      active_total: meta.total_count,
      active_issues: active_issues,
      replacement_issues: list_replacement_issues(assigns),
      resolved_issues: resolved_issues,
      issue_summary: issue_summary
    }
  end

  def active_statuses_for_filter("all"), do: @active_statuses
  def active_statuses_for_filter("resolved"), do: []

  def active_statuses_for_filter(status_filter) when is_binary(status_filter) do
    case Map.fetch(@active_status_filters, status_filter) do
      {:ok, status} -> [status]
      :error -> @active_statuses
    end
  end

  def active_statuses_for_filter(_status_filter), do: @active_statuses

  def list_active_issues(assigns, opts \\ []) do
    page_size = Keyword.get(opts, :per_page, 250)

    fetch_all_issues(
      assigns,
      active_statuses_for_filter(assigns.status_filter),
      page_size
    )
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

  defp fetch_active_issues([], %{per_page: per_page}), do: {[], empty_meta(per_page)}

  defp fetch_active_issues(active_statuses, assigns) do
    Media.list_bad_file_issues(flop_params(assigns), statuses: active_statuses)
  end

  defp fetch_all_issues(_assigns, [], _page_size), do: []

  defp fetch_all_issues(assigns, statuses, page_size) do
    assigns
    |> Map.put(:page, 1)
    |> Map.put(:per_page, page_size)
    |> fetch_all_issues(statuses, page_size, [])
    |> Enum.reverse()
  end

  defp fetch_all_issues(assigns, statuses, page_size, acc) do
    {issues, meta} = fetch_active_issues(statuses, assigns)
    acc = Enum.reverse(issues, acc)

    if more_pages?(meta) do
      assigns
      |> Map.put(:page, meta.current_page + 1)
      |> Map.put(:per_page, page_size)
      |> fetch_all_issues(statuses, page_size, acc)
    else
      acc
    end
  end

  defp fetch_resolved_issues(_assigns, [], _show_resolved), do: []
  defp fetch_resolved_issues(_assigns, _resolved_statuses, false), do: []

  defp fetch_resolved_issues(assigns, resolved_statuses, true) do
    {issues, _} =
      Media.list_bad_file_issues(
        assigns
        |> Map.put(:page, 1)
        |> Map.put(:per_page, assigns.per_page)
        |> flop_params(),
        statuses: resolved_statuses
      )

    issues
  end

  defp list_replacement_issues(assigns) do
    fetch_all_issues(assigns, @replacement_statuses, assigns.per_page)
  end

  defp statuses_for_filter("all"), do: {@active_statuses, @resolved_statuses}
  defp statuses_for_filter("resolved"), do: {[], @resolved_statuses}

  defp statuses_for_filter(status_filter) when is_binary(status_filter) do
    with :error <- Map.fetch(@active_status_filters, status_filter),
         :error <- Map.fetch(@resolved_status_filters, status_filter) do
      {@active_statuses, @resolved_statuses}
    else
      {:ok, status} when status in @active_statuses -> {[status], []}
      {:ok, status} -> {[], [status]}
    end
  end

  defp statuses_for_filter(_status_filter), do: {@active_statuses, @resolved_statuses}

  defp more_pages?(%Flop.Meta{current_page: current_page, total_pages: total_pages})
       when is_integer(current_page) and is_integer(total_pages),
       do: current_page < total_pages

  defp more_pages?(_meta), do: false

  defp empty_meta(per_page) do
    %Flop.Meta{current_page: 1, page_size: per_page, total_count: 0, total_pages: 1}
  end

  defp show_resolved_issues?(%{status_filter: status_filter})
       when status_filter in ["resolved", "replaced_clean", "dismissed"],
       do: true

  defp show_resolved_issues?(assigns), do: assigns.show_resolved
end
