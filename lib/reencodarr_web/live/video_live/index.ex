defmodule ReencodarrWeb.VideoLive.Index do
  use ReencodarrWeb, :live_view

  alias Reencodarr.Media
  alias Reencodarr.Media.Video

  @impl true
  def mount(_params, _session, socket) do
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "videos")
    videos = Media.list_videos()

    {:ok,
     socket
     |> assign(:video_count, length(videos))
     |> assign(:searching_video, nil)
     |> stream(:videos, videos)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  # Handle different actions
  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Video")
    |> assign(:video, Media.get_video!(id))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Video")
    |> assign(:video, %Video{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Videos")
    |> assign(:video, nil)
  end

  # Handle incoming broadcasts
  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{event: "videos", payload: %{action: "upsert", video: video}},
        socket
      ) do
    videos = Media.list_videos()
    video_count = length(videos)

    {:noreply,
     socket
     |> stream_insert(:videos, video, at: 0)
     |> assign(:video_count, video_count)}
  end

  @impl true
  def handle_info(
        %{action: "searching", video: video},
        socket
      ) do
    {:noreply, assign(socket, :searching_video, video.path)}
  end

  @impl true
  def handle_info(
        %{action: "scan_complete", video: _video},
        socket
      ) do
    {:noreply, assign(socket, :searching_video, nil)}
  end

  @impl true
  def handle_info({ReencodarrWeb.VideoLive.FormComponent, {:saved, video}}, socket) do
    videos = Media.list_videos()
    video_count = length(videos)

    {:noreply,
     socket
     |> stream_insert(:videos, video, at: 0)
     |> assign(:video_count, video_count)}
  end

  # Handle delete events
  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    video = Media.get_video!(id)
    {:ok, _} = Media.delete_video(video)

    videos = Media.list_videos()
    video_count = length(videos)

    {:noreply,
     socket
     |> stream_delete(:videos, video)
     |> assign(:video_count, video_count)}
  end
end
