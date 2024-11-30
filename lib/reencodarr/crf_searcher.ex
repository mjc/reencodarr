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
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "videos",
          event: "videos",
          payload: %{action: "upsert", video: video}
        },
        state
      ) do
    run(video)
    {:noreply, state}
  end

  @impl true
  def handle_info(%{action: "crf_search_result", result: {:ok, vmafs}}, state) do
    Logger.debug("Received #{Enum.count(vmafs)} CRF search results")
    Media.process_vmafs(vmafs)
    {:noreply, state}
  end

  @impl true
  def handle_info(%{action: "crf_search_result", result: {:error, reason}}, state) do
    Logger.error("CRF search failed: #{reason}")
    {:noreply, state}
  end

  @impl true
  def handle_info(%{action: action}, state) when action in ["encoding", "encode_result"] do
    Logger.debug("CrfSearcher ignoring encoding messages.")
    {:noreply, state}
  end

  @impl true
  def handle_info(%{action: "encode_result", result: {:error, reason}}, state) do
    Logger.error("Encoding failed: #{reason}")
    {:noreply, state}
  end

  @impl true
  def handle_info(%{action: "crf_search", video: _video}, state), do: {:noreply, state}
  @impl true
  def handle_info(%{action: "scan_complete", video: _video}, state), do: {:noreply, state}

  @spec run(Reencodarr.Media.Video.t()) :: :ok
  def run(%Media.Video{id: video_id, path: path, video_codecs: codecs} = video) do
    case {codec_present?(codecs), Media.chosen_vmaf_exists?(video)} do
      {false, false} ->
        Logger.info("Initiating crf search for video #{video_id}")
        AbAv1.crf_search(video)

      {false, true} ->
        Logger.info("Skipping crf search for video #{path} as a chosen VMAF already exists")

      {true, _} ->
        Logger.debug("Skipping crf search for video #{path} as it already has AV1 codec")
    end

    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "videos", %{action: "scan_complete", video: video})
  end

  defp codec_present?(codecs), do: "V_AV1" in codecs
end
