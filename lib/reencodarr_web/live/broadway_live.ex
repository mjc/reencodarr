defmodule ReencodarrWeb.BroadwayLive do
  @moduledoc "Redirects the retired pipeline monitor to the dashboard."
  use ReencodarrWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, push_navigate(socket, to: ~p"/")}

  @impl true
  def render(assigns), do: ~H"<span>Opening dashboard…</span>"
end
