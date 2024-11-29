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
          payload: %{
            action: "upsert",
            video: video
          }
        },
        state
      ) do
    run(video)
    {:noreply, state}
  end

  @impl true
  def handle_info(%{action: "searching", video: _video}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(%{action: "scan_complete", video: _video}, state) do
    {:noreply, state}
  end

  @spec run(Reencodarr.Media.Video.t()) :: :ok
  def run(%Media.Video{id: video_id, path: path, video_codecs: codecs} = video) do
    with {:codec, false} <- {:codec, "V_AV1" in codecs},
         {:chosen, false} <- {:chosen, Media.chosen_vmaf_exists?(video)} do
      Logger.info("Running crf search for video #{path}")
      vmafs = AbAv1.crf_search(video)
      Logger.info("Found #{length(vmafs)} vmafs for video #{video_id}")
      process_vmafs(vmafs)
      :ok
    else
      {:chosen, true} ->
        Logger.info("Skipping crf search for video #{path} as a chosen VMAF already exists")
        :ok

      {:codec, true} ->
        Logger.debug("Skipping crf search for video #{path} as it already has AV1 codec")
        :ok
    end

    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "videos", %{action: "scan_complete", video: video})

    :ok
  end


  defp process_vmafs(vmafs) do
    vmafs
    |> Enum.map(&Media.upsert_vmaf/1)
    |> tap(fn x -> Enum.each(x, &log_vmaf/1) end)
    |> Enum.any?(&chosen_vmaf?/1)

    # Ensure the function returns the original list
    vmafs
  end

  defp log_vmaf({:ok, %{chosen: true} = vmaf}) do
    Logger.info(
      "Chosen crf: #{vmaf.crf}, chosen score: #{vmaf.score}, chosen percent: #{vmaf.percent}, chosen size: #{vmaf.size}, chosen time: #{vmaf.time}"
    )
  end

  defp log_vmaf(_), do: :ok

  defp chosen_vmaf?({:ok, %{chosen: true}}), do: true
  defp chosen_vmaf?(_), do: false
end
