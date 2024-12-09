defmodule Reencodarr.CrfSearcher do
  use GenServer
  alias Reencodarr.{AbAv1, Media}
  require Logger

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "videos")
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "scanning")
    {:ok, %{}}
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "videos",
          event: "video:upsert",
          payload: %{video: video}
        },
        state
      ) do
    run(video)
    {:noreply, state}
  end

  @impl true
  def handle_info(%{action: "scanning:start", video: video}, state) do
    run(video)
    {:noreply, state}
  end

  @impl true
  def handle_info(%{action: "scanning:progress", vmaf: vmaf}, state) do
    Logger.debug("Received vmaf search progress")
    Media.upsert_vmaf(vmaf)
    {:noreply, state}
  end

  @impl true
  def handle_info(%{action: "scanning:finished", vmaf: vmaf}, state) do
    Media.upsert_vmaf(vmaf)
    {:noreply, state}
  end

  @impl true
  def handle_info(%{action: "scanning:failed", reason: reason}, state) do
    Logger.error("Scanning failed: #{reason}")
    {:noreply, state}
  end

  @impl true
  def handle_info(%{action: "queue:update"}, state) do
    {:noreply, state}
  end

  @spec run(Reencodarr.Media.Video.t()) :: :ok
  def run(%Media.Video{reencoded: true, path: path}) do
    Logger.info("Skipping crf search for video #{path} as it is already reencoded")
    :ok
  end

  def run(%Media.Video{} = video) do
    if Media.chosen_vmaf_exists?(video) do
      Logger.info("Skipping crf search for video #{video.path} as a chosen VMAF already exists")
      :ok
    else
      Logger.debug("Initiating crf search for video #{video.id}")
      AbAv1.crf_search(video)
    end
  end
end
