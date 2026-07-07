defmodule ReencodarrWeb.WorkerChannel do
  @moduledoc """
  Phoenix channel for long-lived ab-av1 CRF-search workers.
  """

  use ReencodarrWeb, :channel

  alias Reencodarr.AbAv1.{WorkerProtocol, WorkerSessions}

  @crf_search_topic WorkerProtocol.crf_search_topic()

  @impl true
  def join(@crf_search_topic, _payload, %{assigns: %{worker_id: worker_id}} = socket) do
    {:ok, %{worker_id: worker_id}, socket}
  end

  def join(_topic, _payload, socket), do: {:error, WorkerProtocol.error(:unauthorized), socket}

  @impl true
  def handle_in("announce", payload, %{assigns: %{worker_id: server_worker_id}} = socket) do
    with {:ok,
          %{
            worker_id: client_worker_id,
            protocol_version: protocol_version,
            version: version,
            capabilities: capabilities
          }} <- WorkerProtocol.parse_announcement(payload),
         true <- WorkerProtocol.supported_protocol_version?(protocol_version),
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
      false ->
        {:reply, {:error, WorkerProtocol.error(:unsupported_protocol_version)}, socket}

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

  def handle_in("pull_work", _payload, socket),
    do: {:reply, {:ok, WorkerProtocol.no_work()}, socket}

  @impl true
  def terminate(_reason, %{assigns: %{worker_id: worker_id}}) do
    WorkerSessions.unregister(worker_id)
    :ok
  end
end
