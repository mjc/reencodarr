defmodule ReencodarrWeb.DashboardLive do
  use ReencodarrWeb, :live_view
  alias Reencodarr.{Media, AbAv1}
  import Phoenix.LiveComponent

  def mount(_params, _session, socket) do
    if connected?(socket), do: ReencodarrWeb.Endpoint.subscribe("scanning")
    stats = Media.fetch_stats()
    queue_length = AbAv1.queue_length()
    lowest_vmaf = Media.get_lowest_chosen_vmaf()
    {:ok, assign(socket, :stats, stats) |> assign(:queue_length, queue_length) |> assign(:lowest_vmaf, lowest_vmaf) |> assign(:progress, %{}) |> assign(:crf_progress, %{})}
  end

  def handle_info(%{action: action} = msg, socket) do
    case action do
      "scanning:start" -> {:noreply, socket}
      "scanning:finished" -> update_stats(socket)
      "scanning:progress" -> update_crf_progress(socket, msg)
      "queue:update" -> update_queue_length(socket, msg.crf_searches, msg.encodes)
      "encoding_progress" -> update_progress(socket, msg)
      _ -> {:noreply, socket}
    end
  end

  def handle_event("start_encode", %{"vmaf_id" => vmaf_id}, socket) do
    vmaf = Media.get_vmaf!(vmaf_id)
    AbAv1.encode(vmaf)
    {:noreply, socket}
  end

  defp update_stats(socket) do
    stats = Media.fetch_stats()
    lowest_vmaf = Media.get_lowest_chosen_vmaf()
    {:noreply, assign(socket, :stats, stats) |> assign(:lowest_vmaf, lowest_vmaf)}
  end

  defp update_queue_length(socket, crf_searches, encodes) do
    {:noreply, assign(socket, :queue_length, %{crf_searches: crf_searches, encodes: encodes})}
  end

  defp update_progress(socket, %{video: video, percent: percent, fps: fps, eta: eta}) do
    progress = %{video_id: video.id, percent: percent, fps: fps, eta: eta}
    {:noreply, assign(socket, :progress, progress)}
  end

  defp update_crf_progress(socket, %{vmaf: vmaf}) do
    if Map.has_key?(vmaf, "video_id") do
      crf_progress = %{video_id: vmaf["video_id"], percent: vmaf["percent"], crf: vmaf["crf"], score: vmaf["score"], target_vmaf: vmaf["target_vmaf"]}
      {:noreply, assign(socket, :crf_progress, crf_progress)}
    else
      {:noreply, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-100 flex flex-col items-center justify-center space-y-8">
      <div class="w-3/4 flex justify-between items-center mb-4">
        <button phx-click="start_encode" phx-value-vmaf_id={@lowest_vmaf.id} class="bg-blue-500 text-white px-4 py-2 rounded shadow">
          Start Encode for Lowest Chosen VMAF
        </button>
      </div>

      <div class="w-3/4">
        <table class="min-w-full bg-white rounded-lg shadow-lg">
          <thead>
            <tr>
              <th class="px-6 py-3 border-b-2 border-gray-300 text-left leading-4 text-gray-600 tracking-wider">Queue Type</th>
              <th class="px-6 py-3 border-b-2 border-gray-300 text-left leading-4 text-gray-600 tracking-wider">Count</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
                <div class="text-sm leading-5 text-gray-800">CRF Searches in Queue</div>
              </td>
              <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
                <div class="text-sm leading-5 text-gray-900"><%= @queue_length.crf_searches %></div>
              </td>
            </tr>
            <tr>
              <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
                <div class="text-sm leading-5 text-gray-800">Encodes in Queue</div>
              </td>
              <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
                <div class="text-sm leading-5 text-gray-900"><%= @queue_length.encodes %></div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="w-3/4">
        <table class="min-w-full bg-white rounded-lg shadow-lg">
          <thead>
            <tr>
              <th class="px-6 py-3 border-b-2 border-gray-300 text-left leading-4 text-gray-600 tracking-wider">Progress Type</th>
              <th class="px-6 py-3 border-b-2 border-gray-300 text-left leading-4 text-gray-600 tracking-wider">Details</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
                <div class="text-sm leading-5 text-gray-800">Encoding Progress</div>
              </td>
              <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
                <%= if Map.has_key?(@progress, :percent) do %>
                  <div class="text-sm leading-5 text-gray-900"><%= @progress.percent %> % @ <%= @progress.fps %> fps, ETA: <%= @progress.eta %> seconds</div>
                <% else %>
                  <div class="text-sm leading-5 text-gray-900">No encoding in progress</div>
                <% end %>
              </td>
            </tr>
            <tr>
              <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
                <div class="text-sm leading-5 text-gray-800">CRF Search Progress</div>
              </td>
              <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
                <%= if Map.has_key?(@crf_progress, :percent) do %>
                  <div class="text-sm leading-5 text-gray-900">CRF: <%= @crf_progress.crf %>, Percent: <%= @crf_progress.percent %> % (of original size), VMAF Score: <%= @crf_progress.score %> (Target: <%= @crf_progress.target_vmaf %>)</div>
                <% else %>
                  <div class="text-sm leading-5 text-gray-900">No CRF search in progress</div>
                <% end %>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="w-3/4">
        <table class="min-w-full bg-white rounded-lg shadow-lg">
          <thead>
            <tr>
              <th class="px-6 py-3 border-b-2 border-gray-300 text-left leading-4 text-gray-600 tracking-wider">Statistic</th>
              <th class="px-6 py-3 border-b-2 border-gray-300 text-left leading-4 text-gray-600 tracking-wider">Value</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
                <div class="text-sm leading-5 text-gray-800">Not Reencoded</div>
              </td>
              <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
                <div class="text-sm leading-5 text-gray-900"><%= @stats[false] || 0 %></div>
              </td>
            </tr>
            <tr>
              <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
                <div class="text-sm leading-5 text-gray-800">Reencoded</div>
              </td>
              <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
                <div class="text-sm leading-5 text-gray-900"><%= @stats[true] || 0 %></div>
              </td>
            </tr>
            <tr>
              <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
                <div class="text-sm leading-5 text-gray-800">Total Videos</div>
              </td>
              <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
                <div class="text-sm leading-5 text-gray-900"><%= @stats.total_videos %></div>
              </td>
            </tr>
            <tr>
              <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
                <div class="text-sm leading-5 text-gray-800">Average VMAF Percentage</div>
              </td>
              <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
                <div class="text-sm leading-5 text-gray-900"><%= @stats.avg_vmaf_percentage %></div>
              </td>
            </tr>
            <tr>
              <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
                <div class="text-sm leading-5 text-gray-800">Lowest Chosen VMAF Percentage</div>
              </td>
              <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
                <div class="text-sm leading-5 text-gray-900"><%= @lowest_vmaf.percent %></div>
              </td>
            </tr>
            <tr>
              <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
                <div class="text-sm leading-5 text-gray-800">Total VMAFs</div>
              </td>
              <td class="px-6 py-4 whitespace-no-wrap border-b border-gray-300">
                <div class="text-sm leading-5 text-gray-900"><%= @stats.total_vmafs %></div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
