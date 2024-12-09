defmodule ReencodarrWeb.ConfigLive.Index do
  use ReencodarrWeb, :live_view

  alias Reencodarr.Services
  alias Reencodarr.Services.Config

  @impl true
  def mount(_params, _session, socket) do
    {:ok, stream(socket, :configs, Services.list_configs())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Config")
    |> assign(:config, Services.get_config!(id))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Config")
    |> assign(:config, %Config{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Configs")
    |> assign(:config, nil)
  end

  @impl true
  def handle_info({ReencodarrWeb.ConfigLive.FormComponent, {:saved, config}}, socket) do
    {:noreply, stream_insert(socket, :configs, config)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    config = Services.get_config!(id)
    {:ok, _} = Services.delete_config(config)

    {:noreply, stream_delete(socket, :configs, config)}
  end
end
