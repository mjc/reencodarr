defmodule Reencodarr.Encoder do
  use GenServer
  require Logger

  alias Reencodarr.{Media, AbAv1}

  @check_interval 5000

  # Public API
  @spec start_link(any()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def get_next_video, do: GenServer.call(__MODULE__, :get_next_video)
  def start, do: GenServer.cast(__MODULE__, :start_encoding)
  def pause, do: GenServer.cast(__MODULE__, :pause_encoding)
  def scanning?, do: GenServer.call(__MODULE__, :scanning?)

  # GenServer Callbacks
  @impl true
  def init(state) do
    Logger.info("Initializing Encoder...")
    monitor_encode()
    {:ok, Map.put(state, :encoding, false)}
  end

  @impl true
  def handle_cast(:start_encoding, state) do
    Logger.debug("Encoding started")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "encoder", {:encoder, :started})
    schedule_check()
    {:noreply, %{state | encoding: true}}
  end

  @impl true
  def handle_cast(:pause_encoding, state) do
    Logger.debug("Encoding paused")
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "encoder", {:encoder, :paused})
    {:noreply, %{state | encoding: false}}
  end

  @impl true
  def handle_cast(:empty, state) do
    Logger.error("Queue is empty")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:encoding_complete, video, output_file}, state) do
    Logger.info("Encoding completed for video #{video.id}")

    new_output_file =
      Path.join(
        Path.dirname(video.path),
        Path.basename(video.path, Path.extname(video.path)) <>
          ".reencoded" <> Path.extname(video.path)
      )

    case File.rename(output_file, new_output_file) do
      :ok ->
        Logger.info("Moved output file #{output_file} to #{new_output_file}")
        Media.mark_as_reencoded(video)

      {:error, :exdev} ->
        case File.cp(output_file, new_output_file) do
          :ok ->
            File.rm(output_file)
            Logger.info("Copied output file #{output_file} to #{new_output_file}")
            Media.mark_as_reencoded(video)

          {:error, reason} ->
            Logger.error("Failed to copy output file: #{reason}")
            Media.mark_as_failed(video)
        end

      {:error, reason} ->
        Logger.error("Failed to move output file: #{reason}")
        Media.mark_as_failed(video)
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:encoding_failed, video, exit_code}, state) do
    Logger.error("Encoding failed for video #{video.id} with exit code #{exit_code}")
    Media.mark_as_failed(video)
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_next_video, %{encoding: true} = state) do
    check_next_video()
    schedule_check()
    {:noreply, state}
  end

  def handle_info(:check_next_video, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(%{action: "encoding:complete", result: {:error, 143}, video: video}, state) do
    Logger.error("Encoding failed with error code 143 for video #{video.id}")
    {:noreply, state}
  end

  @impl true
  def handle_info(%{action: "encoding:complete", result: {:error, exit_code}, video: video}, state) when exit_code != 0 do
    Logger.error("Encoding failed with error code #{exit_code} for video #{video.id}")
    Media.mark_as_failed(video)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    Logger.warning("AbAv1.Encode process crashed or is not yet started.")
    Process.send_after(self(), :monitor_encode, 10_000)
    {:noreply, state}
  end

  @impl true
  def handle_info(:monitor_encode, state) do
    monitor_encode()
    {:noreply, state}
  end

  @impl true
  def handle_call(:scanning?, _from, %{encoding: encoding} = state) do
    {:reply, encoding, state}
  end

  @impl true
  def terminate(_reason, _state) do
    System.cmd("pkill", ["-f", "ab-av1"])
    :ok
  end

  # Private Helper Functions
  defp check_next_video do
    with pid when not is_nil(pid) <- GenServer.whereis(Reencodarr.AbAv1.Encode),
         false <- AbAv1.Encode.running?(),
         chosen_vmaf when not is_nil(chosen_vmaf) <- Media.get_lowest_chosen_vmaf() do
      Logger.debug("Next video to re-encode: #{chosen_vmaf.video.path}")
      AbAv1.encode(chosen_vmaf)
    else
      nil ->
        Logger.error("Encode process is not running.")

      true ->
        Logger.debug("Encoding is already in progress, skipping check for next video.")

      other ->
        Logger.error("No chosen VMAF found for video or some other error: #{inspect(other)}")
    end
  end

  defp schedule_check do
    Process.send_after(self(), :check_next_video, @check_interval)
  end

  defp monitor_encode do
    case GenServer.whereis(Reencodarr.AbAv1.Encode) do
      nil ->
        Logger.error("Encode process is not running.")
        Process.send_after(self(), :monitor_encode, 10_000)

      pid ->
        Process.monitor(pid)
    end
  end
end
