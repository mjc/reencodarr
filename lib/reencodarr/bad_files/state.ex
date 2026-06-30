defmodule Reencodarr.BadFiles.State do
  @moduledoc false

  alias Reencodarr.Media

  @active_statuses [:open, :queued, :processing, :waiting_for_replacement, :failed]
  @resolved_statuses [:replaced_clean, :dismissed]
  @active_status_filters Map.new(@active_statuses, &{Atom.to_string(&1), &1})
  @replacement_statuses [:processing, :waiting_for_replacement]

  @spec load(map(), keyword()) :: map()
  def load(assigns, opts \\ []) do
    include_summary? = Keyword.get(opts, :include_summary, true)
    statuses = statuses_for_filter(assigns.status_filter)
    {issues, meta} = fetch_issues(statuses, assigns)
    issue_summary = issue_summary(assigns, opts, include_summary?)

    %{
      issues: issues,
      meta: meta,
      tracked_count:
        issue_summary.open + issue_summary.queued + issue_summary.processing +
          issue_summary.waiting_for_replacement + issue_summary.failed + issue_summary.resolved,
      active_total: meta.total_count,
      active_issues: issues,
      replacement_issues: list_replacement_issues(assigns),
      resolved_issues: side_resolved_issues(assigns),
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

  defp fetch_all_issues(_assigns, [], _page_size), do: []

  defp fetch_all_issues(assigns, statuses, page_size) do
    assigns
    |> Map.put(:page, 1)
    |> Map.put(:per_page, page_size)
    |> fetch_all_active_issues(statuses, page_size, [])
    |> Enum.reverse()
  end

  defp fetch_all_active_issues(assigns, statuses, page_size, acc) do
    {issues, meta} = fetch_issues(statuses, assigns)
    acc = Enum.reverse(issues, acc)

    if more_pages?(meta) do
      assigns
      |> Map.put(:page, meta.current_page + 1)
      |> Map.put(:per_page, page_size)
      |> fetch_all_active_issues(statuses, page_size, acc)
    else
      acc
    end
  end

  defp list_replacement_issues(assigns) do
    assigns
    |> flop_params()
    |> Media.list_bad_file_issue_previews(
      statuses: @replacement_statuses,
      limit: assigns.per_page
    )
  end

  defp issue_summary(_assigns, _opts, true), do: Media.bad_file_issue_summary()

  defp issue_summary(assigns, opts, false) do
    Keyword.get(opts, :issue_summary) || assigns[:issue_summary] || Media.bad_file_issue_summary()
  end

  defp fetch_issues([], %{per_page: per_page}), do: {[], empty_meta(per_page)}

  defp fetch_issues(statuses, assigns) do
    Media.list_bad_file_issues(flop_params(assigns), statuses: statuses)
  end

  defp side_resolved_issues(%{status_filter: "resolved"}), do: []
  defp side_resolved_issues(%{show_resolved: false}), do: []

  defp side_resolved_issues(assigns) do
    {issues, _meta} = fetch_issues(@resolved_statuses, Map.put(assigns, :page, 1))

    issues
  end

  defp statuses_for_filter("all"), do: @active_statuses
  defp statuses_for_filter("resolved"), do: @resolved_statuses

  defp statuses_for_filter(status_filter) when is_binary(status_filter) do
    case Map.fetch(@active_status_filters, status_filter) do
      {:ok, status} -> [status]
      :error -> @active_statuses
    end
  end

  defp statuses_for_filter(_status_filter), do: @active_statuses

  defp more_pages?(%Flop.Meta{current_page: current_page, total_pages: total_pages})
       when is_integer(current_page) and is_integer(total_pages),
       do: current_page < total_pages

  defp more_pages?(_meta), do: false

  defp empty_meta(per_page) do
    %Flop.Meta{current_page: 1, page_size: per_page, total_count: 0, total_pages: 1}
  end
end
