defmodule ReencodarrWeb.ToggleComponent do
  use ReencodarrWeb, :live_component

  def render(assigns) do
    ~H"""
    <button
      phx-click={@toggle_event}
      class={"text-white px-4 py-2 rounded shadow " <> if @active, do: @active_class, else: @inactive_class}
    >
      {(@active && @active_text) || @inactive_text}
    </button>
    """
  end
end
