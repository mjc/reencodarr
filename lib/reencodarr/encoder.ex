defmodule Reencodarr.Encoder do
  use GenServer
  require Logger

  alias Reencodarr.Media
  alias Reencodarr.AbAv1

  # 5 seconds
  @check_interval 5000

  # Client API

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def get_next_video do
    GenServer.call(__MODULE__, :get_next_video)
  end

  def start_encoding do
    GenServer.cast(__MODULE__, :start_encoding)
  end

  def pause_encoding do
    GenServer.cast(__MODULE__, :pause_encoding)
  end

  # Server Callbacks

  @impl true
  def init(state) do
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "encoding")
    {:ok, Map.put(state, :encoding, false)}
  end

  @impl true
  def handle_cast(:start_encoding, state) do
    Logger.debug("Encoding started")
    schedule_check()
    {:noreply, Map.put(state, :encoding, true)}
  end

  def handle_cast(:pause_encoding, state) do
    Logger.debug("Encoding paused")
    {:noreply, Map.put(state, :encoding, false)}
  end

  @impl true
  def handle_info(:check_next_video, state) do
    if state.encoding do
      check_next_video()
      schedule_check()
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(%{action: "encoding:start", video: video, filename: filename}, state) do
    Logger.info("Started encoding #{filename} for video #{video.id}")
    {:noreply, state}
  end

  @impl true
  def handle_info(
        %{action: "encoding:progress", video: video, percent: percent, fps: fps, eta: eta},
        state
      ) do
    Logger.info(
      "Encoding progress for video #{video.id}: #{percent}% at #{fps} fps, ETA: #{eta} seconds"
    )

    {:noreply, state}
  end

  @impl true
  def handle_info(%{action: "encode:start", video: video, filename: filename}, state) do
    Logger.info("Started encoding #{filename} for video #{video.id}")
    {:noreply, state}
  end

  @impl true
  def handle_info(
        %{action: "encoding:progress", video: video, percent: percent, fps: fps, eta: eta},
        state
      ) do
    Logger.info(
      "Encoding progress for video #{video.id}: #{percent}% at #{fps} fps, ETA: #{eta} seconds"
    )

    {:noreply, state}
  end

  @impl true
  def handle_info(%{action: "encoding:start", video: video}, state) do
    Logger.info("Encoding started for video #{video.id}")
    {:noreply, state}
  end

  @impl true
  def handle_info(%{action: "encode_result", result: {:ok, message}}, state) do
    Logger.info("Encoding completed successfully: #{message}")
    {:noreply, state}
  end

  @impl true
  def handle_info(%{action: "encode_result", result: {:error, reason}}, state) do
    Logger.error("Encoding failed: #{reason}")
    {:noreply, state}
  end

  @impl true
  def handle_info(%{action: "queue:update", crf_searches: crf_searches, encodes: encodes}, state) do
    Logger.info("Queue updated: #{crf_searches} CRF searches, #{encodes} encodes")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    System.cmd("pkill", ["-f", "ab-av1"])
    :ok
  end

  # Helper functions

  defp check_next_video do
    with next_video when not is_nil(next_video) <- Media.find_next_video(),
         chosen_vmaf when not is_nil(chosen_vmaf) <- Media.get_chosen_vmaf_for_video(next_video) do
      Logger.debug("Next video to re-encode: #{next_video.path}")
      AbAv1.encode(chosen_vmaf)
    else
      nil -> Logger.debug("No videos to re-encode")
      _ -> Logger.error("No chosen VMAF found for video")
    end
  end

  defp schedule_check do
    Process.send_after(self(), :check_next_video, @check_interval)
  end
end
