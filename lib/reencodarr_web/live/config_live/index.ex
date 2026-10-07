defmodule ReencodarrWeb.ConfigLive.Index do
  use ReencodarrWeb, :live_view

  alias Reencodarr.Dashboard.{Events, State}
  alias Reencodarr.Services
  alias Reencodarr.Services.Config
  alias Reencodarr.Sync

  @impl true
  def mount(_params, _session, socket) do
    sync = State.get_state().source_sync

    progress =
      if sync, do: %{sync.service_type => %{status: :syncing, progress: sync.progress}}, else: %{}

    if connected?(socket), do: Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())
    {:ok, socket |> assign(:syncs, progress) |> stream(:configs, Services.list_configs())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit source")
    |> assign(:config, Services.get_config!(id))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "Add source")
    |> assign(:config, %Config{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Sources")
    |> assign(:config, nil)
  end

  @impl true
  def handle_info({ReencodarrWeb.ConfigLive.FormComponent, {:saved, config}}, socket) do
    {:noreply, stream_insert(socket, :configs, config)}
  end

  def handle_info({event, %{service_type: service_type} = data}, socket)
      when event in [:sync_started, :sync_progress, :sync_completed, :sync_failed] do
    syncs =
      case event do
        :sync_completed ->
          Map.delete(socket.assigns.syncs, service_type)

        :sync_failed ->
          Map.put(socket.assigns.syncs, service_type, %{status: :failed, progress: 0})

        _ ->
          Map.put(socket.assigns.syncs, service_type, %{
            status: :syncing,
            progress: Map.get(data, :progress, 0)
          })
      end

    {:noreply,
     socket |> assign(:syncs, syncs) |> stream(:configs, Services.list_configs(), reset: true)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    with %Config{} = config <- Services.get_config(id),
         {:ok, updated} <- Services.update_config(config, %{enabled: !config.enabled}) do
      {:noreply, stream_insert(socket, :configs, updated)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Unable to update source")}
    end
  end

  def handle_event("sync_source", %{"id" => id}, socket) do
    with %Config{enabled: true} = config <- Services.get_config(id),
         false <-
           match?(
             %{status: status} when status in [:queued, :syncing],
             socket.assigns.syncs[config.service_type]
           ),
         :ok <- Sync.request_sync(config.service_type) do
      syncs = Map.put(socket.assigns.syncs, config.service_type, %{status: :queued, progress: 0})
      {:noreply, socket |> assign(:syncs, syncs) |> stream_insert(:configs, config)}
    else
      _ ->
        {:noreply,
         put_flash(socket, :error, "Source is disabled, unsupported, or already syncing")}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    config = Services.get_config!(id)
    {:ok, _} = Services.delete_config(config)

    {:noreply, stream_delete(socket, :configs, config)}
  end
end
