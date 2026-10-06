defmodule ReencodarrWeb.WorkersLive do
  @moduledoc "Connected workers, active jobs, and connection setup."
  use ReencodarrWeb, :live_view

  alias Reencodarr.AbAv1.WorkerSessions
  alias Reencodarr.Dashboard.Events
  alias ReencodarrWeb.{DashboardComponents, WorkerActivity, WorkerControl}

  @refresh_interval 5_000
  @worker_control_events WorkerControl.event_names()

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket, workers: [], crf_worker_data: %{}, encode_worker_data: %{})
      |> assign_workers(WorkerSessions.list())

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())
      Process.send_after(self(), :refresh_workers, @refresh_interval)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh_workers, socket) do
    Process.send_after(self(), :refresh_workers, @refresh_interval)
    {:noreply, assign_workers(socket, WorkerSessions.list())}
  end

  def handle_info({:worker_sessions_updated, %{sessions: workers}}, socket),
    do: {:noreply, assign_workers(socket, workers)}

  def handle_info({:crf_search_vmaf_result, %{video_id: id}}, socket),
    do:
      {:noreply,
       assign(
         socket,
         :crf_worker_data,
         WorkerActivity.load_worker_crf_data(
           socket.assigns.workers,
           Map.delete(socket.assigns.crf_worker_data, id)
         )
       )}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event(event, params, socket) when event in @worker_control_events,
    do: WorkerControl.handle_event(event, params, socket)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="workbench">
      <header class="workbench-heading">
        <h1>Workers</h1>
        <span class="connection-label"><span class="status-dot" />{length(@workers)} connected</span>
      </header>
      <div class="worker-list">
        <DashboardComponents.worker_group
          :for={worker <- @workers}
          worker={worker}
          encode_data={@encode_worker_data}
          crf_data={@crf_worker_data}
        />
        <p :if={@workers == []} class="workbench-empty-inline">No workers connected.</p>
        <DashboardComponents.worker_setup />
      </div>
    </div>
    """
  end

  defp assign_workers(socket, workers) do
    assign(socket,
      workers: workers,
      crf_worker_data:
        WorkerActivity.load_worker_crf_data(workers, socket.assigns.crf_worker_data),
      encode_worker_data:
        WorkerActivity.load_worker_encode_data(workers, socket.assigns.encode_worker_data)
    )
  end
end
