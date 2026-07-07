defmodule ReencodarrWeb.WorkerChannel do
  @moduledoc """
  Phoenix channel for long-lived ab-av1 CRF-search workers.
  """

  use ReencodarrWeb, :channel

  alias Reencodarr.AbAv1.{WorkerProtocol, WorkerSessions}
  alias Reencodarr.AbAv1.WorkerProtocol.Announcement
  alias Reencodarr.Media

  @crf_search_topic WorkerProtocol.crf_search_topic()

  @impl true
  def join(@crf_search_topic, _payload, %{assigns: %{worker_id: worker_id}} = socket) do
    {:ok, %{worker_id: worker_id}, socket}
  end

  def join(_topic, _payload, _socket), do: {:error, WorkerProtocol.error(:unauthorized)}

  @impl true
  def handle_in("announce", payload, %{assigns: %{worker_id: server_worker_id}} = socket) do
    with {:ok,
          %Announcement{
            worker_id: client_worker_id,
            protocol_version: protocol_version,
            version: version,
            capabilities: capabilities
          }} <- WorkerProtocol.parse_announcement(payload),
         :ok <- ensure_supported_protocol_version(protocol_version),
         {:ok, _session} <-
           WorkerSessions.register(%{
             server_worker_id: server_worker_id,
             client_worker_id: client_worker_id,
             protocol_version: protocol_version,
             version: version,
             capabilities: capabilities
           }) do
      socket =
        socket
        |> assign(:client_worker_id, client_worker_id)
        |> assign(:client_version, version)
        |> assign(:protocol_version, protocol_version)
        |> assign(:capabilities, capabilities)

      {:reply, {:ok, WorkerProtocol.accepted(protocol_version)}, socket}
    else
      {:error, reason} ->
        {:reply, {:error, WorkerProtocol.error(reason)}, socket}
    end
  end

  def handle_in("heartbeat", _payload, %{assigns: %{worker_id: worker_id}} = socket) do
    case WorkerSessions.touch(worker_id) do
      {:ok, session} ->
        {:reply, {:ok, WorkerProtocol.heartbeat_ack(session.last_seen_at)}, socket}

      {:error, reason} ->
        {:reply, {:error, WorkerProtocol.error(reason)}, socket}
    end
  end

  def handle_in("request_work", payload, socket), do: handle_work_request(payload, socket)

  def handle_in("pull_work", payload, socket), do: handle_work_request(payload, socket)

  def handle_in(_event, _payload, socket) do
    {:reply, {:error, WorkerProtocol.error(:unsupported_event)}, socket}
  end

  defp ensure_supported_protocol_version(protocol_version) do
    if WorkerProtocol.supported_protocol_version?(protocol_version) do
      :ok
    else
      {:error, :unsupported_protocol_version}
    end
  end

  @impl true
  def terminate(_reason, %{assigns: %{worker_id: worker_id}} = socket) do
    maybe_requeue_active_video(socket)
    WorkerSessions.unregister(worker_id)
    :ok
  end

  defp handle_work_request(_payload, %{assigns: %{worker_id: worker_id}} = socket) do
    case socket.assigns[:current_video_id] do
      nil ->
        claim_work(worker_id, socket)

      video_id ->
        case Media.get_video(video_id) do
          %Media.Video{} = video ->
            {:reply,
             {:ok, WorkerProtocol.work_assigned(video, socket.assigns[:current_vmaf_target])},
             socket}

          nil ->
            {:reply, {:error, WorkerProtocol.error(:unknown_worker_session)}, socket}
        end
    end
  end

  defp claim_work(worker_id, socket) do
    case Media.claim_next_video_for_crf_search() do
      %Media.Video{} = video ->
        assign_claimed_work(worker_id, socket, video)

      nil ->
        {:reply, {:ok, WorkerProtocol.no_work()}, socket}
    end
  end

  defp assign_claimed_work(worker_id, socket, video) do
    target_vmaf = Reencodarr.Rules.vmaf_target(video)

    case WorkerSessions.assign_video(worker_id, video.id) do
      {:ok, _session} ->
        socket =
          socket
          |> assign(:current_video_id, video.id)
          |> assign(:current_vmaf_target, target_vmaf)

        {:reply, {:ok, WorkerProtocol.work_assigned(video, target_vmaf)}, socket}

      {:error, reason} ->
        _ = Media.mark_as_analyzed(video)
        {:reply, {:error, WorkerProtocol.error(reason)}, socket}
    end
  end

  defp maybe_requeue_active_video(socket) do
    case socket.assigns[:current_video_id] do
      nil ->
        :ok

      video_id ->
        case Media.get_video(video_id) do
          %Media.Video{state: :crf_searching} = video ->
            _ = Media.mark_as_analyzed(video)
            :ok

          _ ->
            :ok
        end
    end
  end
end
