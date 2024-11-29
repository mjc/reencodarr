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
    Logger.info("Running crf search for video #{video.path}")
    vmafs = AbAv1.crf_search(video)
    dbg(vmafs)
    Logger.info("Found #{length(vmafs)} vmafs for video #{video.id}")
    {count, nil} = Repo.delete_all(Media.Vmaf, where: [video_id: video.id])
    Logger.info("Deleted #{count} vmafs for video #{video.id}")
    Enum.map(vmafs, &Media.create_vmaf/1)
    |> Enum.find(fn
      {:ok, %{chosen: true} = vmaf} ->
        Logger.info("Chosen crf: #{vmaf.crf}, chosen score: #{vmaf.score}, chosen size: #{vmaf.size}, chosen time: #{vmaf.time}")
        true
      _ -> false
    end)
    :ok
  end
end
