defmodule Reencodarr.CrfSearcher do
  use GenServer
  alias Reencodarr.{AbAv1, Media, Repo}
  require Logger

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "videos")
    {:ok, %{}}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{
    topic: "videos", event: "videos", payload: %{
      action: "upsert", video: video}}, state) do
    run(video)
    {:noreply, state}
  end

  @spec run(Reencodarr.Media.Video.t()) :: :ok
  def run(video) do
    Logger.debug("Running crf search for video #{video.path}")
    vmafs = AbAv1.crf_search(video)
    Logger.debug("Found #{length(vmafs)} vmafs for video #{video.id}")
    {count, nil} = Repo.delete_all(Media.Vmaf, where: [video_id: video.id])
    Logger.debug("Deleted #{count} vmafs for video #{video.id}")
    Enum.map(vmafs, &Media.create_vmaf/1)
    :ok
  end
end
