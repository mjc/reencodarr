defmodule ReencodarrWeb.WorkerChannel do
  @moduledoc """
  Phoenix channel for long-lived ab-av1 CRF-search workers.
  """

  use ReencodarrWeb, :channel

  alias Reencodarr.AbAv1.WorkerProtocol

  @crf_search_topic WorkerProtocol.crf_search_topic()

  @impl true
  def join(@crf_search_topic, _payload, %{assigns: %{worker_id: worker_id}} = socket) do
    {:ok, %{worker_id: worker_id}, socket}
  end

  def join(_topic, _payload, socket), do: {:error, WorkerProtocol.error(:unauthorized), socket}

  @impl true
  def handle_in("announce", payload, socket) do
    case WorkerProtocol.parse_announcement(payload) do
      {:ok, %{worker_id: worker_id, version: version, capabilities: capabilities}} ->
        socket =
          socket
          |> assign(:client_worker_id, worker_id)
          |> assign(:client_version, version)
          |> assign(:capabilities, capabilities)

        {:reply, {:ok, WorkerProtocol.accepted()}, socket}

      {:error, reason} ->
        {:reply, {:error, WorkerProtocol.error(reason)}, socket}
    end
  end

  def handle_in("pull_work", _payload, socket),
    do: {:reply, {:ok, WorkerProtocol.no_work()}, socket}
end
