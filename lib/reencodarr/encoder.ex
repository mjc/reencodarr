defmodule Reencodarr.Encoder do
  use GenServer
  require Logger

  alias Reencodarr.Media
  alias Reencodarr.AbAv1

  @check_interval 5000  # 5 seconds

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
      next_video = Media.find_next_video()
      if next_video do
        Logger.debug("Next video to re-encode: #{next_video.path}")
        chosen_vmaf = Media.get_chosen_vmaf_for_video(next_video)
        case AbAv1.encode(chosen_vmaf) do
          {:ok, _result} ->
            Media.mark_as_reencoded(next_video)
            Logger.debug("Marked #{next_video.path} as re-encoded")
          {:error, reason} ->
            Logger.error("Failed to encode #{next_video.path}: #{reason}")
            raise "Encoding failed"
        end
      else
        Logger.debug("No videos to re-encode")
      end
      schedule_check()
    end
    {:noreply, state}
  end

  # Helper functions

  defp schedule_check do
    Process.send_after(self(), :check_next_video, @check_interval)
  end
end
