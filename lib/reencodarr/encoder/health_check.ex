defmodule Reencodarr.Encoder.HealthCheck do
  @moduledoc """
  Monitors the encoder pipeline for stuck states.

  Detects when ab-av1/ffmpeg hangs silently (port alive but no progress)
  and automatically kills the stuck process after 1 hour.
  """

  use GenServer
  require Logger

  alias Reencodarr.Dashboard.Events

  # Check every 60 seconds
  @check_interval 60_000
  # Warn at 30 minutes
  @warn_threshold 30 * 60_000
  # Kill at 1 hour
  @kill_threshold 60 * 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule_check()
    {:ok, %{last_progress_time: nil, last_progress_percent: nil, warned: false}}
  end

  @impl true
  def handle_info(:health_check, state) do
    new_state = perform_health_check(state)
    schedule_check()
    {:noreply, new_state}
  end

  defp perform_health_check(state) do
    case get_encode_state() do
      {:ok, encode_state} ->
        check_encoder(encode_state, state)

      :error ->
        state
    end
  end

  defp get_encode_state do
    case GenServer.whereis(Reencodarr.AbAv1.Encode) do
      nil ->
        :error

      pid ->
        try do
          {:ok, :sys.get_state(pid)}
        catch
          :exit, _ -> :error
        end
    end
  end

  defp check_encoder(%{port: :none}, state) do
    # Not encoding, reset state
    %{state | last_progress_time: nil, last_progress_percent: nil, warned: false}
  end

  defp check_encoder(encode_state, state) do
    now = System.monotonic_time(:millisecond)
    current_percent = encode_state.last_progress && encode_state.last_progress.percent

    cond do
      # Progress changed - reset timer
      current_percent != state.last_progress_percent ->
        %{state | last_progress_time: now, last_progress_percent: current_percent, warned: false}

      # No progress time yet (just started tracking)
      state.last_progress_time == nil ->
        %{state | last_progress_time: now}

      # Stuck for 1 hour - kill the process
      now - state.last_progress_time > @kill_threshold ->
        kill_stuck_encoder(encode_state)
        %{state | last_progress_time: nil, last_progress_percent: nil, warned: false}

      # Stuck for 30 min - warn
      now - state.last_progress_time > @warn_threshold and not state.warned ->
        warn_stuck_encoder(encode_state)
        %{state | warned: true}

      true ->
        state
    end
  end

  defp warn_stuck_encoder(encode_state) do
    video_id = encode_state.video != :none && encode_state.video.id
    video_path = encode_state.video != :none && encode_state.video.path

    Logger.warning(
      "Encoder may be stuck - no progress for 30+ minutes. " <>
        "Video ID: #{video_id}, Path: #{video_path}"
    )

    Events.broadcast_event(:encoder_health_alert, %{
      reason: :stalled_30_min,
      video_id: video_id,
      video_path: video_path
    })
  end

  defp kill_stuck_encoder(encode_state) do
    video_id = encode_state.video != :none && encode_state.video.id
    video_path = encode_state.video != :none && encode_state.video.path

    case Port.info(encode_state.port, :os_pid) do
      {:os_pid, pid} ->
        Logger.error(
          "Killing stuck encoder process (PID: #{pid}) after 1 hour of no progress. " <>
            "Video ID: #{video_id}, Path: #{video_path}"
        )

        System.cmd("kill", [to_string(pid)])

        Events.broadcast_event(:encoder_health_alert, %{
          reason: :killed_stuck_process,
          video_id: video_id,
          video_path: video_path,
          os_pid: pid
        })

      _ ->
        Logger.error(
          "Could not get OS PID for stuck encoder port. " <>
            "Video ID: #{video_id}, Path: #{video_path}"
        )
    end
  end

  defp schedule_check, do: Process.send_after(self(), :health_check, @check_interval)
end
