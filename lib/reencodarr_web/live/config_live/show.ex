defmodule ReencodarrWeb.ConfigLive.Show do
  use ReencodarrWeb, :live_view

  alias Reencodarr.Services

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:config, Services.get_config!(id))}
  end

  defp page_title(:show), do: "Show Config"
  defp page_title(:edit), do: "Edit Config"
end
