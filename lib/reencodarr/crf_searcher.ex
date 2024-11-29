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
    {:ok, %{}}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{topic: "videos", event: "videos", payload: %{action: "upsert", video: video}}, state) do
    run(video)
    {:noreply, state}
  end

  @impl true
  def handle_info(%{action: "searching", video: _video}, state), do: {:noreply, state}
  @impl true
  def handle_info(%{action: "scan_complete", video: _video}, state), do: {:noreply, state}

  @spec run(Reencodarr.Media.Video.t()) :: :ok
  def run(%Media.Video{id: video_id, path: path, video_codecs: codecs} = video) do
    case {codec_present?(codecs), Media.chosen_vmaf_exists?(video)} do
      {false, false} ->
        Logger.info("Running crf search for video #{path}")
        vmafs = AbAv1.crf_search(video)
        Logger.info("Found #{length(vmafs)} vmafs for video #{video_id}")
        Media.process_vmafs(vmafs)

      {false, true} ->
        Logger.info("Skipping crf search for video #{path} as a chosen VMAF already exists")

      {true, _} ->
        Logger.debug("Skipping crf search for video #{path} as it already has AV1 codec")
    end
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "videos", %{action: "scan_complete", video: video})
  end

  defp codec_present?(codecs), do: "V_AV1" in codecs
end
