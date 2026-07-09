defmodule ReencodarrWeb.WorkersLive do
  @moduledoc """
  LiveView for connected ab-av1 workers and their current status.
  """

  use ReencodarrWeb, :live_view

  alias Reencodarr.AbAv1.WorkerSessions
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Formatters
  alias Reencodarr.Media
  alias Reencodarr.Rules

  import ReencodarrWeb.CrfSearchComponents

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
  def handle_event("pause_worker_crf_search", %{"worker-id" => worker_id}, socket) do
    control_worker(socket, worker_id, :pause, "Worker pause requested")
  end

  def handle_event("resume_worker_crf_search", %{"worker-id" => worker_id}, socket) do
    control_worker(socket, worker_id, :resume, "Worker resume requested")
  end

  def handle_event("stop_worker_crf_search", %{"worker-id" => worker_id}, socket) do
    control_worker(socket, worker_id, :stop, "Worker stop requested")
  end

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

        <%= if @workers == [] do %>
          <div class="rounded-lg border border-gray-800 bg-gray-900 px-4 py-8 text-center text-sm text-gray-500">
            No workers connected.
          </div>
        <% else %>
          <div class="space-y-3">
            <%= for worker <- @workers do %>
              <section class="grid gap-3 lg:grid-cols-[16rem_minmax(0,1fr)]">
                <aside class="rounded-lg border border-gray-800 bg-gray-900 p-3 sm:p-4">
                  <div class="flex flex-wrap items-center justify-between gap-2 lg:block">
                    <div class="min-w-0">
                      <div class="truncate font-medium text-white">{worker.client_worker_id}</div>
                      <div class="mt-1 truncate text-xs text-gray-500">
                        server: {worker.server_worker_id}
                      </div>
                    </div>
                    <span class={status_badge_class(worker)}>
                      {worker_status(worker)}
                    </span>
                  </div>

                  <%= if worker_resource_usage?(worker) do %>
                    <div class="mt-4 text-xs">
                      <h2 class="mb-2 text-xs font-semibold uppercase tracking-wide text-gray-500">
                        Resources
                      </h2>
                      <div class="space-y-1 text-gray-300">
                        <div>CPU {worker_cpu(worker)}</div>
                        <div class="text-gray-500">Mem {worker_memory(worker)}</div>
                        <div class="text-gray-500">Disk {worker_disk(worker)}</div>
                      </div>
                    </div>
                  <% end %>
                </aside>

                <div class="min-w-0">
                  <%= case worker_phase(worker) do %>
                    <% :receiving_input -> %>
                      <.transfer_panel
                        worker={worker}
                        video={active_video(worker)}
                        title="Receiving Input"
                      />
                    <% :input_ready -> %>
                      <.transfer_panel
                        worker={worker}
                        video={active_video(worker)}
                        title="Input Ready"
                      />
                    <% :crf_searching -> %>
                      <.crf_search_panel
                        video={worker_crf_video(worker)}
                        results={worker_crf_results(worker)}
                        sample={worker_crf_sample(worker)}
                        status={worker_crf_status(worker)}
                        show_controls={true}
                        show_queue={false}
                        show_empty_chart={true}
                        suspend_event="pause_worker_crf_search"
                        resume_event="resume_worker_crf_search"
                        fail_event="stop_worker_crf_search"
                        worker_id={worker.server_worker_id}
                      />
                    <% :idle -> %>
                      <.idle_panel />
                  <% end %>
                </div>
              </section>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp idle_panel(assigns) do
    ~H"""
    <div class="dashboard-card rounded-lg border border-gray-800 bg-gray-900 p-3 sm:p-4">
      <h3 class="font-semibold text-white">Idle</h3>
      <div class="mt-3 text-sm text-gray-500">Waiting for work.</div>
    </div>
    """
  end

  defp control_worker(socket, worker_id, action, message) do
    Phoenix.PubSub.broadcast(
      Reencodarr.PubSub,
      ReencodarrWeb.WorkerChannel.worker_control_topic(worker_id),
      {:worker_control, action}
    )

    {:noreply, put_flash(socket, :info, message)}
  end

  defp transfer_panel(assigns) do
    ~H"""
    <div class="dashboard-card rounded-lg border border-gray-700 bg-gray-900 p-3 sm:p-4">
      <div class="mb-3 flex flex-wrap items-center justify-between gap-2">
        <h3 class="font-semibold text-white">{@title}</h3>
        <span class="rounded-full bg-blue-100 px-2 py-1 text-xs text-blue-800">
          {format_number(@worker.transfer_progress && @worker.transfer_progress.percent)}%
        </span>
      </div>

      <%= if @video do %>
        <div class="text-sm text-gray-300">
          <div class="truncate font-medium">{Path.basename(@video.path)}</div>
          <div class="flex flex-wrap gap-2 text-xs text-gray-400">
            <span>{Formatters.file_size(@video.size)}</span>
            <span>{format_dimensions(@video)}</span>
            <%= if @video.hdr do %>
              <span class="text-amber-400">HDR</span>
            <% end %>
            <span>Target: {Rules.vmaf_target(@video)} VMAF</span>
          </div>
        </div>
      <% end %>

      <%= if @worker.transfer_progress do %>
        <div class="mt-4 space-y-2">
          <div class="h-2 overflow-hidden rounded-full bg-gray-800">
            <div
              class="h-full rounded-full bg-cyan-500 transition-[width] duration-300"
              style={"width: #{progress_width(@worker.transfer_progress.percent)};"}
            >
            </div>
          </div>

          <div class="grid gap-x-4 gap-y-1 text-xs text-gray-400 sm:grid-cols-4">
            <span>{format_transfer_bytes(@worker.transfer_progress)}</span>
            <span>Chunk {format_chunk_progress(@worker.transfer_progress)}</span>
            <span>{format_throughput(Map.get(@worker.transfer_progress, :bytes_per_second))}</span>
            <span>ETA {format_eta(Map.get(@worker.transfer_progress, :eta))}</span>
          </div>
        </div>
      <% else %>
        <div class="mt-3 text-sm text-gray-500">Waiting for work.</div>
      <% end %>
    </div>
    """
  end

  defp worker_status(worker) do
    case worker_phase(worker) do
      :idle -> "Idle"
      :receiving_input -> "Receiving input"
      :input_ready -> "Input ready"
      :crf_searching -> "CRF search"
    end
  end

  defp worker_crf_status(%{phase: :crf_searching}), do: :processing

  defp worker_crf_status(_worker), do: :idle

  defp worker_phase(%{phase: phase})
       when phase in [:idle, :receiving_input, :input_ready, :crf_searching],
       do: phase

  defp worker_phase(%{active_video_id: nil}), do: :idle

  defp worker_phase(%{transfer_progress: progress}) when not is_nil(progress),
    do: :receiving_input

  defp worker_phase(%{active_video_id: video_id}) when is_integer(video_id), do: :crf_searching
  defp worker_phase(_worker), do: :idle

  defp worker_crf_video(worker) do
    case active_video(worker) do
      %Media.Video{} = video ->
        %{
          video_id: video.id,
          filename: Path.basename(video.path),
          video_size: video.size,
          width: video.width,
          height: video.height,
          hdr: video.hdr,
          target_vmaf: Rules.vmaf_target(video)
        }

      nil ->
        nil
    end
  end

  defp worker_crf_results(worker) do
    case active_video_id(worker) do
      nil ->
        []

      video_id ->
        video_id
        |> Media.get_vmafs_for_video()
        |> Enum.sort_by(& &1.crf)
        |> Enum.map(fn vmaf ->
          %{crf: vmaf.crf, score: vmaf.score, percent: vmaf.percent}
        end)
    end
  end

  defp worker_crf_sample(%{
         crf_search_progress: %{crf: crf, sample_num: sample_num, total_samples: total_samples}
       })
       when is_number(crf) and is_integer(sample_num) and is_integer(total_samples) do
    %{crf: crf, sample_num: sample_num, total_samples: total_samples}
  end

  defp worker_crf_sample(_worker), do: nil

  defp active_video(worker) do
    case active_video_id(worker) do
      nil -> nil
      video_id -> Media.get_video(video_id)
    end
  end

  defp active_video_id(%{active_video_id: video_id}) when is_integer(video_id), do: video_id
  defp active_video_id(%{crf_search_progress: %{video_id: video_id}}), do: video_id
  defp active_video_id(%{transfer_progress: %{video_id: video_id}}), do: video_id
  defp active_video_id(_worker), do: nil

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

  defp worker_resource_usage?(%{resource_usage: usage}) when is_map(usage),
    do: map_size(usage) > 0

  defp worker_resource_usage?(_worker), do: false

  defp format_number(number) when is_integer(number), do: Integer.to_string(number)

  defp format_number(number) when is_float(number) do
    :erlang.float_to_binary(number, decimals: 1)
  end

  defp format_number(nil), do: "-"

  defp progress_width(percent) when is_number(percent) do
    percent
    |> max(0)
    |> min(100)
    |> format_number()
    |> Kernel.<>("%")
  end

  defp progress_width(_percent), do: "0%"

  defp format_dimensions(%{width: width, height: height})
       when is_integer(width) and is_integer(height),
       do: "#{width}x#{height}"

  defp format_dimensions(_video), do: "unknown resolution"

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

  defp format_transfer_bytes(%{bytes_sent: bytes_sent, total_bytes: total_bytes}),
    do: format_transfer_bytes(bytes_sent, total_bytes)

  defp format_chunk_progress(%{chunk_index: chunk_index, total_chunks: total_chunks})
       when is_integer(chunk_index) and is_integer(total_chunks) and total_chunks > 0 do
    "#{chunk_index + 1} / #{total_chunks}"
  end

  defp format_chunk_progress(%{chunk_index: chunk_index}) when is_integer(chunk_index),
    do: Integer.to_string(chunk_index)

  defp format_chunk_progress(_), do: "-"

  defp status_badge_class(worker) do
    case worker_phase(worker) do
      :idle ->
        "inline-flex rounded-full border border-emerald-900 bg-emerald-950 px-2 py-1 text-xs font-medium text-emerald-300"

      _active ->
        "inline-flex rounded-full border border-cyan-900 bg-cyan-950 px-2 py-1 text-xs font-medium text-cyan-300"
    end
  end
end
