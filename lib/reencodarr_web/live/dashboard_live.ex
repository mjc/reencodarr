defmodule ReencodarrWeb.DashboardLive do
  use ReencodarrWeb, :live_view
  alias Reencodarr.{Media, AbAv1}
  import Phoenix.LiveComponent

  def mount(_params, _session, socket) do
    if connected?(socket), do: ReencodarrWeb.Endpoint.subscribe("scanning")
    if connected?(socket), do: ReencodarrWeb.Endpoint.subscribe("queue")
    if connected?(socket), do: ReencodarrWeb.Endpoint.subscribe("encoding")
    if connected?(socket), do: ReencodarrWeb.Endpoint.subscribe("videos")
    stats = Media.fetch_stats()
    queue_length = AbAv1.queue_length()
    lowest_vmaf = Media.get_lowest_chosen_vmaf() || %Media.Vmaf{}
    lowest_vmaf_by_time = Media.get_lowest_chosen_vmaf_by_time() || %Media.Vmaf{}

    {:ok,
     assign(socket, :stats, stats)
     |> assign(:queue_length, queue_length)
     |> assign(:lowest_vmaf, lowest_vmaf)
     |> assign(:lowest_vmaf_by_time, lowest_vmaf_by_time)
     |> assign(:progress, %{})
     |> assign(:crf_progress, %{})}
  end

  def handle_info(%{action: "scanning:start"} = _msg, socket) do
    {:noreply, socket}
  end

  def handle_info(%{action: "scanning:finished"} = _msg, socket) do
    stats = Media.fetch_stats()
    lowest_vmaf = Media.get_lowest_chosen_vmaf() || %Media.Vmaf{}
    lowest_vmaf_by_time = Media.get_lowest_chosen_vmaf_by_time() || %Media.Vmaf{}

    {:noreply,
     assign(socket, :stats, stats)
     |> assign(:lowest_vmaf, lowest_vmaf)
     |> assign(:lowest_vmaf_by_time, lowest_vmaf_by_time)}
  end

  def handle_info(%{action: "scanning:progress", vmaf: vmaf} = _msg, socket) do
    if Map.has_key?(vmaf, "video_id") do
      crf_progress = %{
        video_id: vmaf["video_id"],
        percent: vmaf["percent"],
        crf: vmaf["crf"],
        score: vmaf["score"],
        target_vmaf: vmaf["target_vmaf"]
      }

      {:noreply, assign(socket, :crf_progress, crf_progress)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        %{action: "queue:update", crf_searches: crf_searches, encodes: encodes} = _msg,
        socket
      ) do
    {:noreply, assign(socket, :queue_length, %{crf_searches: crf_searches, encodes: encodes})}
  end

  def handle_info(%{action: "encoding:start", video: video, filename: filename} = _msg, socket) do
    progress = %{video_id: video.id, filename: filename}
    {:noreply, assign(socket, :progress, progress)}
  end

  def handle_info(
        %{
          action: "encoding:progress",
          video: video,
          percent: percent,
          fps: fps,
          eta: eta,
          human_readable_eta: human_readable_eta
        } = _msg,
        socket
      ) do
    progress = %{
      video_id: video.id,
      percent: percent,
      fps: fps,
      eta: eta,
      human_readable_eta: human_readable_eta
    }

    {:noreply, assign(socket, :progress, progress)}
  end

  def handle_info(%{action: "video:upsert"} = _msg, socket) do
    stats = Media.fetch_stats()
    lowest_vmaf = Media.get_lowest_chosen_vmaf() || %Media.Vmaf{}
    lowest_vmaf_by_time = Media.get_lowest_chosen_vmaf_by_time() || %Media.Vmaf{}

    {:noreply,
     assign(socket, :stats, stats)
     |> assign(:lowest_vmaf, lowest_vmaf)
     |> assign(:lowest_vmaf_by_time, lowest_vmaf_by_time)}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  def handle_event("start_encode", %{"vmaf_id" => vmaf_id}, socket) do
    vmaf = Media.get_vmaf!(vmaf_id)
    AbAv1.encode(vmaf, :insert_at_top)
    {:noreply, socket}
  end

  def handle_event("start_encode_by_time", %{"vmaf_id" => vmaf_id}, socket) do
    vmaf = Media.get_vmaf!(vmaf_id)
    AbAv1.encode(vmaf, :insert_at_top)
    {:noreply, socket}
  end

  def handle_event("queue_next_5_lowest_vmafs", _params, socket) do
    vmafs = Media.list_chosen_vmafs() |> Enum.take(5)
    Enum.each(vmafs, fn vmaf -> AbAv1.encode(vmaf, :insert_at_top) end)
    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-100 dark:bg-gray-900 flex flex-col items-center justify-center space-y-8">
      <div class="w-full flex justify-between items-center mb-4 px-4">
        <button
          phx-click="start_encode"
          phx-value-vmaf_id={@lowest_vmaf.id}
          class="bg-blue-500 text-white px-4 py-2 rounded shadow"
        >
          Queue Encode Manually
        </button>
        <button
          phx-click="start_encode_by_time"
          phx-value-vmaf_id={@lowest_vmaf_by_time.id}
          class="bg-green-500 text-white px-4 py-2 rounded shadow"
        >
          Queue Encode by Time
        </button>
        <button
          phx-click="queue_next_5_lowest_vmafs"
          class="bg-red-500 text-white px-4 py-2 rounded shadow"
        >
          Queue Next 5 Lowest VMAFs
        </button>
      </div>

      <div class="w-full grid grid-cols-1 md:grid-cols-2 gap-4 px-4">
        <.live_component
          module={ReencodarrWeb.QueueComponent}
          id="queue-component"
          queue_length={@queue_length}
        />
        <.live_component
          module={ReencodarrWeb.ProgressComponent}
          id="progress-component"
          progress={@progress}
          crf_progress={@crf_progress}
        />
        <.live_component
          module={ReencodarrWeb.StatsComponent}
          id="stats-component"
          stats={@stats}
          lowest_vmaf={@lowest_vmaf}
        />
      </div>
    </div>
    """
  end
end
