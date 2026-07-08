defmodule ReencodarrWeb.WorkersLive do
  @moduledoc """
  LiveView for connected ab-av1 workers and their current status.
  """

  use ReencodarrWeb, :live_view

  alias Reencodarr.AbAv1.WorkerSessions
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Formatters
  alias Reencodarr.Media

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, :workers, WorkerSessions.list())

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())
      Process.send_after(self(), :refresh_workers, @refresh_interval)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh_workers, socket) do
    Process.send_after(self(), :refresh_workers, @refresh_interval)
    {:noreply, assign(socket, :workers, WorkerSessions.list())}
  end

  @impl true
  def handle_info({:worker_sessions_updated, %{sessions: sessions}}, socket) do
    {:noreply, assign(socket, :workers, sessions)}
  end

  def handle_info({_event, _data}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-[calc(100dvh-3.5rem)] bg-gray-950 px-3 py-4 sm:px-4 sm:py-6 lg:px-6">
      <div class="mx-auto max-w-7xl space-y-4">
        <div class="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p class="text-xs uppercase tracking-[0.2em] text-cyan-400">ab-av1</p>
            <h1 class="mt-1 text-2xl font-semibold text-white">Workers</h1>
            <p class="mt-1 text-sm text-gray-400">
              Connected worker sessions and their current job state.
            </p>
          </div>

          <div class="flex items-center gap-2">
            <div class="rounded-full border border-cyan-900 bg-cyan-950 px-3 py-1 text-xs text-cyan-300">
              Connected {length(@workers)}
            </div>
            <.link
              navigate={~p"/"}
              class="rounded-full border border-gray-800 bg-gray-900 px-3 py-1 text-xs text-gray-300 hover:border-cyan-700 hover:text-white"
            >
              Dashboard
            </.link>
          </div>
        </div>

        <div class="overflow-hidden rounded-lg border border-gray-800 bg-gray-900">
          <table class="min-w-full divide-y divide-gray-800 text-sm">
            <thead class="bg-gray-950/60 text-xs uppercase tracking-wide text-gray-500">
              <tr>
                <th class="px-4 py-3 text-left font-medium">Worker</th>
                <th class="px-4 py-3 text-left font-medium">State</th>
                <th class="px-4 py-3 text-left font-medium">Video</th>
                <th class="px-4 py-3 text-left font-medium">Resources</th>
                <th class="px-4 py-3 text-left font-medium">Live Progress</th>
                <th class="px-4 py-3 text-left font-medium">CRF/VMAF Results</th>
                <th class="px-4 py-3 text-left font-medium">Protocol</th>
                <th class="px-4 py-3 text-left font-medium">Version</th>
                <th class="px-4 py-3 text-left font-medium">Connected</th>
                <th class="px-4 py-3 text-left font-medium">Last Seen</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-800">
              <%= if @workers == [] do %>
                <tr>
                  <td colspan="10" class="px-4 py-8 text-center text-sm text-gray-500">
                    No workers connected.
                  </td>
                </tr>
              <% end %>

              <%= for worker <- @workers do %>
                <tr class="text-gray-200">
                  <td class="px-4 py-3">
                    <div class="font-medium text-white">{worker.client_worker_id}</div>
                    <div class="mt-1 text-xs text-gray-500">
                      server: {worker.server_worker_id}
                    </div>
                  </td>
                  <td class="px-4 py-3">
                    <span class={status_badge_class(worker)}>
                      {worker_status(worker)}
                    </span>
                  </td>
                  <td class="px-4 py-3 text-gray-300">
                    {worker_video(worker)}
                  </td>
                  <td class="px-4 py-3 text-xs text-gray-300">
                    <div>CPU {worker_cpu(worker)}</div>
                    <div class="mt-1 text-gray-500">Mem {worker_memory(worker)}</div>
                    <div class="mt-1 text-gray-500">Disk {worker_disk(worker)}</div>
                  </td>
                  <td class="px-4 py-3 text-xs text-gray-300">
                    <div>{worker_progress(worker)}</div>
                    <div class="mt-1 text-gray-500">{worker_transfer(worker)}</div>
                  </td>
                  <td class="px-4 py-3 text-xs text-gray-300">
                    {worker_vmafs(worker)}
                  </td>
                  <td class="px-4 py-3 text-gray-300">
                    {worker.protocol_version}
                  </td>
                  <td class="px-4 py-3 text-gray-300">
                    {worker.version}
                  </td>
                  <td class="px-4 py-3 text-gray-300">
                    {DateTime.to_iso8601(worker.connected_at)}
                  </td>
                  <td class="px-4 py-3 text-gray-300">
                    {DateTime.to_iso8601(worker.last_seen_at)}
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

  defp worker_status(%{active_video_id: nil}), do: "Idle"

  defp worker_status(%{active_video_id: video_id}) do
    case Media.get_video(video_id) do
      %Media.Video{state: state} -> Atom.to_string(state)
      nil -> "missing"
    end
  end

  defp worker_video(%{active_video_id: nil}), do: "none"
  defp worker_video(%{active_video_id: video_id}), do: "video ##{video_id}"

  defp worker_cpu(%{resource_usage: %{cpu_percent: cpu_percent}}) when is_number(cpu_percent),
    do: "#{format_number(cpu_percent)}%"

  defp worker_cpu(_worker), do: "-"

  defp worker_memory(%{resource_usage: %{memory_bytes: memory_bytes} = usage})
       when is_integer(memory_bytes) do
    case Map.get(usage, :memory_total_bytes) do
      total when is_integer(total) and total > 0 ->
        "#{Formatters.file_size(memory_bytes)} / #{Formatters.file_size(total)}"

      _ ->
        Formatters.file_size(memory_bytes)
    end
  end

  defp worker_memory(_worker), do: "-"

  defp worker_disk(%{resource_usage: %{disk_free_bytes: disk_free_bytes} = usage})
       when is_integer(disk_free_bytes) do
    case Map.get(usage, :disk_total_bytes) do
      total when is_integer(total) and total > 0 ->
        "#{Formatters.file_size(disk_free_bytes)} free / #{Formatters.file_size(total)}"

      _ ->
        "#{Formatters.file_size(disk_free_bytes)} free"
    end
  end

  defp worker_disk(_worker), do: "-"

  defp worker_progress(%{crf_search_progress: nil}), do: "CRF -"

  defp worker_progress(%{crf_search_progress: progress}) do
    [
      {"CRF", progress.percent, &"#{format_number(&1)}%"},
      {"FPS", progress.fps, &Formatters.fps/1},
      {"ETA", progress.eta, &"#{&1}s"}
    ]
    |> format_parts()
  end

  defp worker_transfer(%{transfer_progress: nil}), do: "Transfer -"

  defp worker_transfer(%{transfer_progress: progress}) do
    parts = [
      {"Transfer", progress.percent, &"#{format_number(&1)}%"},
      {"Throughput", progress.bytes_per_second, &format_throughput/1},
      {"ETA", progress.eta, &format_eta/1},
      {"Bytes", progress.bytes_sent, &format_transfer_bytes(&1, progress.total_bytes)},
      {"Chunk", progress.chunk_index, &to_string/1},
      {"Total", progress.total_chunks, &to_string/1}
    ]

    case format_parts(parts) do
      "-" -> "-"
      details -> progress_filename(progress) <> details
    end
  end

  defp worker_vmafs(%{active_video_id: nil}), do: "-"

  defp worker_vmafs(%{active_video_id: video_id}) do
    video_id
    |> Media.get_vmafs_for_video()
    |> Enum.sort_by(& &1.crf)
    |> Enum.take(4)
    |> case do
      [] ->
        "-"

      vmafs ->
        Enum.map_join(vmafs, " / ", &format_vmaf/1)
    end
  end

  defp format_vmaf(vmaf) do
    "CRF #{Formatters.crf(vmaf.crf)} -> #{Formatters.vmaf_score(vmaf.score, 1)} (#{format_number(vmaf.percent)}%)"
  end

  defp progress_filename(%{filename: nil}), do: ""
  defp progress_filename(%{filename: filename}), do: "#{filename} - "

  defp format_parts(parts) do
    parts
    |> Enum.reject(fn {_label, value, _formatter} -> is_nil(value) end)
    |> Enum.map(fn {label, value, formatter} ->
      "#{label} #{formatter.(value)}"
    end)
    |> case do
      [] -> "-"
      formatted -> Enum.join(formatted, " / ")
    end
  end

  defp format_number(number) when is_integer(number), do: Integer.to_string(number)

  defp format_number(number) when is_float(number) do
    :erlang.float_to_binary(number, decimals: 1)
  end

  defp format_number(nil), do: "-"

  defp format_throughput(bytes_per_second)
       when is_integer(bytes_per_second) and bytes_per_second >= 0 do
    "#{Formatters.file_size(bytes_per_second)}/s"
  end

  defp format_throughput(_), do: "-"

  defp format_eta(seconds) when is_integer(seconds) and seconds >= 0, do: "#{seconds}s"
  defp format_eta(_), do: "-"

  defp format_transfer_bytes(bytes_sent, total_bytes)
       when is_integer(bytes_sent) and bytes_sent >= 0 and is_integer(total_bytes) and
              total_bytes > 0 do
    "#{Formatters.file_size(bytes_sent)} / #{Formatters.file_size(total_bytes)}"
  end

  defp format_transfer_bytes(bytes_sent, _total_bytes)
       when is_integer(bytes_sent) and bytes_sent >= 0,
       do: Formatters.file_size(bytes_sent)

  defp format_transfer_bytes(_bytes_sent, _total_bytes), do: "-"

  defp status_badge_class(%{active_video_id: nil}),
    do:
      "inline-flex rounded-full border border-emerald-900 bg-emerald-950 px-2 py-1 text-xs font-medium text-emerald-300"

  defp status_badge_class(%{active_video_id: _video_id}),
    do:
      "inline-flex rounded-full border border-cyan-900 bg-cyan-950 px-2 py-1 text-xs font-medium text-cyan-300"
end
