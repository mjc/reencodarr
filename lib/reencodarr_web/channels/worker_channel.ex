defmodule ReencodarrWeb.WorkerChannel do
  @moduledoc """
  Phoenix channel for long-lived ab-av1 CRF-search workers.
  """

  use ReencodarrWeb, :channel

  @impl true
  def join("workers:crf_search", _payload, %{assigns: %{worker_id: worker_id}} = socket) do
    {:ok, %{worker_id: worker_id}, socket}
  end

  def join(_topic, _payload, socket), do: {:error, %{reason: "unauthorized"}, socket}

  @impl true
  def handle_in("announce", payload, socket) do
    case payload do
      %{"worker_id" => worker_id, "version" => version, "capabilities" => capabilities}
      when is_binary(worker_id) and is_binary(version) and is_map(capabilities) ->
        socket =
          socket
          |> assign(:client_worker_id, worker_id)
          |> assign(:client_version, version)
          |> assign(:capabilities, capabilities)

        {:reply, {:ok, %{accepted: true}}, socket}

      _invalid ->
        {:reply, {:error, %{reason: "invalid_announcement"}}, socket}
    end
  end

  def handle_in("pull_work", _payload, socket), do: {:reply, {:ok, %{status: "no_work"}}, socket}
end
