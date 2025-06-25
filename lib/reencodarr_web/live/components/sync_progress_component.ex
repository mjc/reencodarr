defmodule ReencodarrWeb.SyncProgressComponent do
  use Phoenix.LiveComponent

  attr :sync_progress, :integer, required: true

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.live_component
        module={ReencodarrWeb.ProgressDetailComponent}
        id={"#{@id}-detail"}
        title={if @sync_progress > 0, do: "Sync Progress", else: nil}
        progress_percent={if @sync_progress > 0, do: @sync_progress, else: nil}
        progress_color="indigo"
        show_when_inactive={false}
      />
    </div>
    """
  end
end
