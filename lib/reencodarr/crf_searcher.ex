defmodule Reencodarr.CrfSearcher do
  use GenServer
  alias Reencodarr.{AbAv1, Media, Repo}
  require Logger
  import Ecto.Query

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

  @impl true
  def handle_info(%{action: "searching", video: _video}, state) do
    {:noreply, state}
  end

  @spec run(Reencodarr.Media.Video.t()) :: :ok
  def run(%Media.Video{id: video_id, path: path, video_codecs: codecs} = video) do
    cond do
      Media.chosen_vmaf_exists?(video) ->
        Logger.info("Skipping crf search for video #{path} as a chosen VMAF already exists")
        :ok

      "V_AV1" in codecs ->
        Logger.info("Skipping crf search for video #{path} as it already has AV1 codec")
        :ok

      true ->
        Logger.info("Running crf search for video #{path}")
        vmafs = AbAv1.crf_search(video)
        Logger.info("Found #{length(vmafs)} vmafs for video #{video_id}")
        {count, _} = Repo.delete_all(from v in Media.Vmaf, where: v.video_id == ^video_id)
        Logger.info("Deleted #{count} vmafs for video #{video_id}")

        vmafs
        |> Enum.map(&Media.create_vmaf/1)
        |> Enum.find(fn
          {:ok, %{chosen: true} = vmaf} ->
            Logger.info("Chosen crf: #{vmaf.crf}, chosen score: #{vmaf.score}, chosen size: #{vmaf.size}, chosen time: #{vmaf.time}")
            true
          _ -> false
        end)

        :ok
    end
  end
end
