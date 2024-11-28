defmodule ReencodarrWeb.VmafLive.Show do
  use ReencodarrWeb, :live_view

  alias Reencodarr.Media

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:vmaf, Media.get_vmaf!(id))}
  end

  defp page_title(:show), do: "Show Vmaf"
  defp page_title(:edit), do: "Edit Vmaf"
end
