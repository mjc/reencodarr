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
  def handle_info(%{action: "queue:update"}, state) do
    {:noreply, state}
  end

  @spec run(Reencodarr.Media.Video.t()) :: :ok
  def run(%Media.Video{id: video_id, path: path, video_codecs: codecs} = video) do
    case {codec_present?(codecs), Media.chosen_vmaf_exists?(video)} do
      {false, false} ->
        Logger.debug("Initiating crf search for video #{video_id}")
        AbAv1.crf_search(video)

      {false, true} ->
        Logger.info("Skipping crf search for video #{path} as a chosen VMAF already exists")

      {true, _} ->
        Logger.debug("Skipping crf search for video #{path} as it already has AV1 codec")
    end
  end

  defp codec_present?(codecs), do: "V_AV1" in codecs
end
