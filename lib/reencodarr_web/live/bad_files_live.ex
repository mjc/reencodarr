defmodule ReencodarrWeb.BadFilesLive do
  use ReencodarrWeb, :live_view

  alias Reencodarr.Core.Parsers
  alias Reencodarr.Media

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load_issues(socket)}
  end

  @impl true
  def handle_event("enqueue_issue", %{"id" => id_str}, socket) do
    with {:ok, id} <- Parsers.parse_integer_exact(id_str),
         issue <- Media.get_bad_file_issue!(id),
         {:ok, _queued_issue} <- Media.enqueue_bad_file_issue(issue) do
      {:noreply, socket |> put_flash(:info, "Queued bad-file issue") |> load_issues()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed to queue bad-file issue")}
    end
  end

  @impl true
  def handle_event("dismiss_issue", %{"id" => id_str}, socket) do
    with {:ok, id} <- Parsers.parse_integer_exact(id_str),
         issue <- Media.get_bad_file_issue!(id),
         {:ok, _dismissed_issue} <- Media.dismiss_bad_file_issue(issue) do
      {:noreply, socket |> put_flash(:info, "Dismissed bad-file issue") |> load_issues()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed to dismiss bad-file issue")}
    end
  end

  @impl true
  def handle_event("retry_issue", %{"id" => id_str}, socket) do
    with {:ok, id} <- Parsers.parse_integer_exact(id_str),
         issue <- Media.get_bad_file_issue!(id),
         {:ok, _retried_issue} <- Media.retry_bad_file_issue(issue) do
      {:noreply, socket |> put_flash(:info, "Re-queued bad-file issue") |> load_issues()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed to re-queue bad-file issue")}
    end
  end

  defp load_issues(socket) do
    assign(socket, :issues, Media.list_bad_file_issues())
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-900 p-6">
      <div class="max-w-6xl mx-auto space-y-4">
        <div>
          <h1 class="text-3xl font-bold text-white">Bad Files</h1>
          <p class="text-gray-400">{length(@issues)} tracked</p>
        </div>

        <div class="bg-gray-800 rounded-lg border border-gray-700 overflow-hidden">
          <table class="min-w-full divide-y divide-gray-700 text-sm">
            <thead class="bg-gray-700/80">
              <tr>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-300 uppercase tracking-wider">
                  File
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-300 uppercase tracking-wider">
                  Reason
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-300 uppercase tracking-wider">
                  Status
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-300 uppercase tracking-wider">
                  Actions
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-600">
              <%= for issue <- @issues do %>
                <tr>
                  <td class="px-4 py-3 text-gray-200">
                    {Path.basename(issue.video.path)}
                  </td>
                  <td class="px-4 py-3 text-gray-300">
                    {issue.manual_reason || issue.classification}
                    <%= if issue.manual_note && issue.manual_note != "" do %>
                      <div class="text-xs text-gray-500">{issue.manual_note}</div>
                    <% end %>
                  </td>
                  <td class="px-4 py-3 text-gray-300">{issue.status}</td>
                  <td class="px-4 py-3">
                    <div class="flex gap-2">
                      <button
                        id={"enqueue-issue-#{issue.id}"}
                        phx-click="enqueue_issue"
                        phx-value-id={issue.id}
                        class="text-emerald-300 hover:text-emerald-200 text-xs"
                      >
                        queue
                      </button>
                      <button
                        id={"retry-issue-#{issue.id}"}
                        phx-click="retry_issue"
                        phx-value-id={issue.id}
                        class="text-blue-300 hover:text-blue-200 text-xs"
                      >
                        retry
                      </button>
                      <button
                        id={"dismiss-issue-#{issue.id}"}
                        phx-click="dismiss_issue"
                        phx-value-id={issue.id}
                        class="text-red-300 hover:text-red-200 text-xs"
                      >
                        dismiss
                      </button>
                    </div>
                  </td>
                </tr>
              <% end %>
              <%= if @issues == [] do %>
                <tr>
                  <td colspan="4" class="px-6 py-10 text-center text-gray-500">
                    No bad-file issues tracked.
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end
end
