defmodule ReencodarrWeb.FailuresComponents do
  @moduledoc "Failure filtering, rows, and diagnostic details."
  use ReencodarrWeb, :html

  def page(assigns) do
    ~H"""
    <div class="workbench page-stack">
      <div class="page-stack">
        <ReencodarrWeb.Layouts.issue_tabs active={:failures} />
        <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <h1 class="text-2xl font-bold text-[var(--wb-text)] sm:text-3xl">
              Failures ({@total_count})
            </h1>
            <p class="text-[var(--wb-muted)]">
              Processing failures and retry actions.
            </p>
          </div>
          <div class="flex flex-col gap-2 sm:flex-row">
            <%= if MapSet.size(@selected_videos) > 0 do %>
              <button
                phx-click="retry_selected"
                class="w-full px-4 py-2 text-sm font-medium text-[var(--wb-text)] bg-[#294362] rounded-md transition-colors hover:bg-[var(--wb-raised)] sm:w-auto"
              >
                Retry selected ({MapSet.size(@selected_videos)})
              </button>
            <% end %>
            <button
              phx-click="reset_all_failures"
              class="w-full px-4 py-2 text-sm font-medium text-[var(--wb-text)] bg-[#55373e] rounded-md transition-colors hover:bg-[var(--wb-raised)] sm:w-auto"
            >
              Reset all
            </button>
          </div>
        </div>

        <%= if @loading do %>
          <div class="bg-[var(--wb-panel)] rounded-md shadow-none p-12 border border-[var(--wb-line)] text-center">
            <p class="text-[var(--wb-muted)]" role="status">Loading failures…</p>
          </div>
        <% else %>
          <.failure_filter_bar
            search_term={@search_term}
            failure_filter={@failure_filter}
            category_filter={@category_filter}
          />

          <.retry_failure_code_panel actions={@failure_code_actions} />
          <.failure_table
            failed_videos={@failed_videos}
            video_failures={@video_failures}
            selected_videos={@selected_videos}
            expanded_details={@expanded_details}
            search_term={@search_term}
            meta={@meta}
            url_query={@url_query}
          />
          <.common_failure_patterns patterns={@failure_patterns} />
        <% end %>
      </div>
    </div>
    """
  end

  # Private Helper Functions

  attr :search_term, :string, required: true
  attr :failure_filter, :string, required: true
  attr :category_filter, :string, required: true

  defp failure_filter_bar(assigns) do
    assigns =
      assign(assigns,
        stage_options: [
          {"all", "All", "bg-[#46395e] text-[var(--wb-text)]"},
          {"analysis", "Analysis", "bg-[#46395e] text-[var(--wb-text)]"},
          {"crf_search", "CRF", "bg-[#294362] text-[var(--wb-text)]"},
          {"encoding", "Encoding", "bg-amber-600 text-[var(--wb-text)]"},
          {"post_process", "Post", "bg-[#55373e] text-[var(--wb-text)]"}
        ],
        category_options: [
          {"all", "All"},
          {"process_failure", "Process"},
          {"timeout", "Timeout"},
          {"codec_issues", "Codec"},
          {"file_access", "File"}
        ]
      )

    ~H"""
    <div class="bg-[var(--wb-panel)] rounded-md shadow-none p-4 border border-[var(--wb-line)]">
      <div class="flex flex-col gap-3">
        <form id="failures-search" phx-change="search" phx-no-unused-field>
          <input
            type="text"
            name="search"
            value={@search_term}
            placeholder="Search by file path..."
            phx-debounce="300"
            aria-label="Search failed videos by file path"
            class="w-full px-4 py-2 bg-[var(--wb-raised)] border border-[var(--wb-line)] rounded-md focus:ring-2 focus:outline-[var(--wb-blue)] focus:outline-[var(--wb-blue)] text-[var(--wb-text)] placeholder:text-[var(--wb-muted)]"
          />
        </form>

        <div class="flex flex-col gap-3 sm:flex-row">
          <div class="flex flex-col gap-2 sm:flex-row sm:items-center">
            <span class="text-sm font-medium text-[var(--wb-muted)] whitespace-nowrap">Stage:</span>
            <div class="inline-flex flex-wrap gap-1" role="group" aria-label="Filter by stage">
              <%= for {value, label, active_class} <- @stage_options do %>
                <button
                  phx-click="filter_failures"
                  phx-value-filter={value}
                  aria-pressed={@failure_filter == value}
                  class={failure_filter_button_class(@failure_filter == value, active_class)}
                >
                  {label}
                </button>
              <% end %>
            </div>
          </div>

          <div class="flex flex-col gap-2 sm:flex-row sm:items-center">
            <span class="text-sm font-medium text-[var(--wb-muted)] whitespace-nowrap">Type:</span>
            <div class="inline-flex flex-wrap gap-1" role="group" aria-label="Filter by category">
              <%= for {value, label} <- @category_options do %>
                <button
                  phx-click="filter_category"
                  phx-value-category={value}
                  aria-pressed={@category_filter == value}
                  class={
                    failure_filter_button_class(
                      @category_filter == value,
                      "bg-[#304e40] text-[var(--wb-text)]"
                    )
                  }
                >
                  {label}
                </button>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp failure_filter_button_class(true, active_class),
    do: "px-2 py-1 text-xs rounded transition-colors #{active_class}"

  defp failure_filter_button_class(false, _active_class),
    do:
      "px-2 py-1 text-xs rounded transition-colors bg-[var(--wb-raised)] text-[var(--wb-muted)] hover:bg-[var(--wb-raised)]"

  attr :actions, :list, required: true

  defp retry_failure_code_panel(assigns) do
    ~H"""
    <%= if @actions != [] do %>
      <div class="bg-[var(--wb-panel)] rounded-md shadow-none p-4 border border-[var(--wb-line)]">
        <div class="flex flex-col gap-3">
          <div>
            <h2 class="text-sm font-semibold text-[var(--wb-text)]">Retry by error code</h2>
            <p class="text-xs text-[var(--wb-muted)]">
              Retry matching failures from analysis.
            </p>
          </div>
          <div class="flex flex-wrap gap-2">
            <%= for action <- @actions do %>
              <button
                phx-click="retry_failure_code"
                phx-value-code={action.code}
                class="inline-flex items-center gap-2 rounded-md border border-[var(--wb-line)] bg-gray-750 px-3 py-2 text-xs font-medium text-[var(--wb-text)] transition-colors hover:bg-[var(--wb-raised)]"
              >
                <span>{action.code}</span>
                <span class="rounded bg-[var(--wb-base)] px-1.5 py-0.5 text-[11px] text-[var(--wb-muted)]">
                  {action.count}
                </span>
              </button>
            <% end %>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  attr :failed_videos, :list, required: true
  attr :video_failures, :map, required: true
  attr :selected_videos, MapSet, required: true
  attr :expanded_details, :list, required: true
  attr :search_term, :string, required: true
  attr :meta, Flop.Meta, required: true
  attr :url_query, :map, required: true

  defp failure_table(assigns) do
    ~H"""
    <div class="bg-[var(--wb-panel)] rounded-md shadow-none overflow-hidden border border-[var(--wb-line)]">
      <%= if @failed_videos == [] do %>
        <div class="p-12 text-center">
          <h3 class="text-xl font-semibold text-[var(--wb-text)] mb-2">No unresolved failures</h3>
          <p class="text-[var(--wb-muted)]">
            <%= if @search_term != "" do %>
              No failures match this search.
            <% else %>
              No unresolved processing failures.
            <% end %>
          </p>
        </div>
      <% else %>
        <div class="divide-y divide-[var(--wb-line)]">
          <div class="failure-row grid grid-cols-[auto_minmax(0,1fr)_auto_auto_auto_auto] gap-3 px-3 py-3 bg-gray-750 text-xs font-semibold text-[var(--wb-muted)] normal-case tracking-normal sm:gap-4 sm:px-4">
            <div class="flex items-center">
              <%= if MapSet.size(@selected_videos) == length(@failed_videos) and length(@failed_videos) > 0 do %>
                <input
                  type="checkbox"
                  checked
                  phx-click="deselect_all"
                  aria-label="Deselect all failed videos on this page"
                  class="w-4 h-4 text-blue-600 bg-[var(--wb-raised)] border-[var(--wb-line)] rounded focus:outline-[var(--wb-blue)] cursor-pointer"
                />
              <% else %>
                <input
                  type="checkbox"
                  phx-click="select_all"
                  aria-label="Select all failed videos on this page"
                  class="w-4 h-4 text-blue-600 bg-[var(--wb-raised)] border-[var(--wb-line)] rounded focus:outline-[var(--wb-blue)] cursor-pointer"
                />
              <% end %>
            </div>
            <div>Video</div>
            <div>Size</div>
            <div>Error</div>
            <div>When</div>
            <div></div>
          </div>

          <%= for video <- @failed_videos do %>
            <% latest_failure = latest_failure(@video_failures, video.id) %>

            <div class="hover:bg-gray-750">
              <div class="failure-row grid grid-cols-[auto_minmax(0,1fr)_auto_auto_auto_auto] gap-3 px-3 py-3 cursor-pointer sm:gap-4 sm:px-4">
                <div
                  class="flex items-center"
                  phx-click="toggle_select"
                  phx-value-video_id={video.id}
                >
                  <input
                    type="checkbox"
                    checked={MapSet.member?(@selected_videos, video.id)}
                    aria-label={"Select failed video #{Path.basename(video.path)}"}
                    class="w-4 h-4 text-blue-600 bg-[var(--wb-raised)] border-[var(--wb-line)] rounded focus:outline-[var(--wb-blue)] cursor-pointer pointer-events-none"
                  />
                </div>

                <div class="min-w-0">
                  <button
                    phx-click="toggle_details"
                    phx-value-video_id={video.id}
                    aria-expanded={video.id in @expanded_details}
                    class="block w-full text-left text-sm font-medium text-[var(--wb-text)] truncate"
                    title={video.path}
                  >
                    {Path.basename(video.path)}
                  </button>
                  <div class="flex flex-wrap items-center gap-2 mt-1 text-xs text-[var(--wb-muted)]">
                    <%= if video.service_type do %>
                      <span>{video.service_type}</span>
                      <span>·</span>
                    <% end %>
                    <%= if video.width && video.height do %>
                      <span>{Reencodarr.Formatters.resolution(video.width, video.height)}</span>
                      <span>·</span>
                    <% end %>
                    <%= if video.video_codecs && length(video.video_codecs) > 0 do %>
                      <span>{format_codecs(video.video_codecs)}</span>
                    <% end %>
                    <%= if video.hdr do %>
                      <span>·</span>
                      <span class="text-[var(--wb-lilac)]">DV</span>
                    <% end %>
                  </div>
                </div>

                <div class="flex items-center text-sm text-[var(--wb-muted)]">
                  <%= if video.size do %>
                    {Reencodarr.Formatters.file_size(video.size)}
                  <% else %>
                    <span class="text-[var(--wb-muted)]">—</span>
                  <% end %>
                </div>

                <div class="flex items-center min-w-0">
                  <.failure_summary failure={latest_failure} />
                </div>

                <div class="flex items-center text-xs text-[var(--wb-muted)]">
                  <%= if latest_failure do %>
                    {compact_relative_time(latest_failure.inserted_at)}
                  <% else %>
                    —
                  <% end %>
                </div>

                <div class="flex items-center">
                  <button
                    phx-click="retry_failed_video"
                    phx-value-video_id={video.id}
                    class="px-3 py-1 text-xs font-medium text-[var(--wb-text)] bg-[#294362] rounded hover:bg-[var(--wb-raised)] transition-colors"
                  >
                    Retry
                  </button>
                </div>
              </div>

              <%= if video.id in @expanded_details do %>
                <.failure_details failures={Map.get(@video_failures, video.id)} />
              <% end %>
            </div>
          <% end %>
        </div>

        <.flop_pagination
          id="failures-flop-pagination"
          meta={@meta}
          base_path="/failures"
          query={@url_query}
          mode={:full}
          page_links={5}
          class="p-4 border-t border-[var(--wb-line)]"
        />
      <% end %>
    </div>
    """
  end

  attr :failure, :any, required: true

  defp failure_summary(assigns) do
    ~H"""
    <%= if @failure do %>
      <div class="flex items-start gap-2">
        <div class={"w-2 h-2 rounded-md mt-1.5 flex-shrink-0 #{stage_color(@failure.failure_stage)}"}>
        </div>
        <div class="min-w-0">
          <div class="text-xs font-semibold text-[var(--wb-text)]">{@failure.failure_stage}</div>
          <div class="text-xs text-[var(--wb-muted)] truncate" title={@failure.failure_code}>
            <%= if @failure.failure_code do %>
              {@failure.failure_code}
            <% else %>
              {@failure.failure_category}
            <% end %>
          </div>
          <div class="text-xs text-[var(--wb-muted)] truncate" title={@failure.failure_message}>
            {truncate_failure_message(@failure.failure_message)}
          </div>
        </div>
      </div>
    <% else %>
      <span class="text-xs text-[var(--wb-muted)]">No failure info</span>
    <% end %>
    """
  end

  attr :failures, :any, required: true

  defp failure_details(assigns) do
    ~H"""
    <div class="px-4 py-4 bg-gray-800/50 border-t border-[var(--wb-line)]">
      <%= case @failures do %>
        <% failures when is_list(failures) and failures != [] -> %>
          <% latest = List.first(failures) %>

          <div class="mb-3">
            <div class="text-xs font-semibold text-[var(--wb-muted)] mb-1">Failure</div>
            <div class="bg-[var(--wb-base)] p-3 rounded text-xs text-[var(--wb-text)] whitespace-pre-wrap">
              {latest.failure_message}
            </div>
          </div>

          <%= if Map.get(latest.system_context || %{}, "command") do %>
            <div class="mb-3">
              <div class="text-xs font-semibold text-[var(--wb-muted)] mb-1">Command</div>
              <div class="bg-[var(--wb-base)] p-3 rounded tabular-nums text-xs text-green-400 overflow-x-auto">
                $ {Map.get(latest.system_context, "command")}
              </div>
            </div>
          <% end %>

          <%= if has_command_details?(latest.system_context) do %>
            <div class="mb-3">
              <div class="text-xs font-semibold text-[var(--wb-muted)] mb-1">Output</div>
              <div class="bg-[var(--wb-base)] p-3 rounded tabular-nums text-xs text-orange-300 overflow-x-auto max-h-60 overflow-y-auto">
                <pre class="whitespace-pre-wrap">{format_command_output(
                  Map.get(latest.system_context, "full_output")
                )}</pre>
              </div>
            </div>
          <% end %>

          <%= if length(failures) > 1 do %>
            <div>
              <div class="text-xs font-semibold text-[var(--wb-muted)] mb-2">
                History ({length(failures)} failures)
              </div>
              <div class="flex flex-wrap gap-2 text-xs">
                <%= for failure <- failures do %>
                  <span
                    class="px-2 py-1 bg-[var(--wb-raised)] text-[var(--wb-muted)] rounded"
                    title={failure.failure_message}
                  >
                    {failure.failure_stage}/{failure.failure_code || failure.failure_category} ({compact_relative_time(
                      failure.inserted_at
                    )})
                  </span>
                <% end %>
              </div>
            </div>
          <% end %>
        <% _ -> %>
          <div class="text-xs text-[var(--wb-muted)]">No detailed failure information available</div>
      <% end %>
    </div>
    """
  end

  attr :patterns, :list, required: true

  defp common_failure_patterns(assigns) do
    ~H"""
    <%= if @patterns != [] do %>
      <div class="bg-[var(--wb-panel)] rounded-md shadow-none p-6 border border-[var(--wb-line)]">
        <h2 class="text-xl font-semibold text-[var(--wb-text)] mb-4">Common Patterns</h2>
        <div class="space-y-2">
          <%= for pattern <- @patterns do %>
            <div class="flex items-center justify-between px-4 py-2 bg-gray-750 rounded">
              <div class="flex items-center gap-3">
                <div class={"w-2 h-2 rounded-md flex-shrink-0 #{stage_color(pattern.stage)}"}></div>
                <div>
                  <span class="text-sm font-medium text-[var(--wb-text)]">
                    {pattern.stage}/{pattern.category}
                  </span>
                  <%= if pattern.code do %>
                    <span class="text-sm text-[var(--wb-muted)] ml-1">{pattern.code}</span>
                  <% end %>
                </div>
              </div>
              <div class="text-right">
                <div class="text-lg font-bold text-yellow-400">{pattern.count}</div>
                <div class="text-xs text-[var(--wb-muted)]">occurrences</div>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  defp latest_failure(video_failures, video_id) do
    case Map.get(video_failures, video_id) do
      [failure | _rest] -> failure
      _ -> nil
    end
  end

  defp truncate_failure_message(message) do
    message = message || ""
    suffix = if String.length(message) > 40, do: "...", else: ""
    String.slice(message, 0, 40) <> suffix
  end

  defp format_codecs(codecs), do: Reencodarr.Formatters.codec_list(codecs)

  defp format_command_output(output) when is_binary(output) and output != "" do
    # Clean up common command output formatting issues
    output
    # Windows line endings
    |> String.replace(~r/\r\n/, "\n")
    # Old Mac line endings
    |> String.replace(~r/\r/, "\n")
  end

  defp format_command_output(_), do: ""

  defp has_command_details?(system_context) do
    command = Map.get(system_context || %{}, "command")
    output = Map.get(system_context || %{}, "full_output", "")

    !is_nil(command) or output != ""
  end

  # Compact relative time formatting for table view
  defp compact_relative_time(nil), do: "N/A"

  defp compact_relative_time(%NaiveDateTime{} = datetime) do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> compact_relative_time()
  end

  defp compact_relative_time(%DateTime{} = datetime) do
    diff_seconds = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff_seconds < 60 -> "#{diff_seconds}s"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m"
      diff_seconds < 86_400 -> "#{div(diff_seconds, 3600)}h"
      diff_seconds < 2_592_000 -> "#{div(diff_seconds, 86_400)}d"
      diff_seconds < 31_556_952 -> "#{div(diff_seconds, 2_629_746)}mo"
      true -> "#{div(diff_seconds, 31_556_952)}y"
    end
  end

  defp compact_relative_time(_), do: "N/A"

  # Get color class for failure stage
  defp stage_color(stage) do
    case stage do
      :analysis -> "bg-purple-500"
      :crf_search -> "bg-blue-500"
      :encoding -> "bg-amber-500"
      :post_process -> "bg-red-500"
      _ -> "bg-gray-500"
    end
  end
end
