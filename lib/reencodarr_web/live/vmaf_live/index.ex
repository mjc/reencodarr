defmodule ReencodarrWeb.VmafLive.Index do
  use ReencodarrWeb, :live_view

  alias Reencodarr.Media
  alias Reencodarr.Media.Vmaf

  @impl true
  def mount(_params, _session, socket) do
    {:ok, stream(socket, :vmafs, Media.list_vmafs())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Vmaf")
    |> assign(:vmaf, Media.get_vmaf!(id))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Vmaf")
    |> assign(:vmaf, %Vmaf{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Vmafs")
    |> assign(:vmaf, nil)
  end

  @impl true
  def handle_info({ReencodarrWeb.VmafLive.FormComponent, {:saved, vmaf}}, socket) do
    {:noreply, stream_insert(socket, :vmafs, vmaf)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    vmaf = Media.get_vmaf!(id)
    {:ok, _} = Media.delete_vmaf(vmaf)

    {:noreply, stream_delete(socket, :vmafs, vmaf)}
  end
end
