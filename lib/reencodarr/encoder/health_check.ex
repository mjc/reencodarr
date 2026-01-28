defmodule Reencodarr.Encoder.HealthCheck do
  @moduledoc """
  Monitors the encoder pipeline for stuck states via PubSub events.

  Subscribes to encoding events and detects when ab-av1/ffmpeg hangs silently
  (no progress events for extended periods). Automatically kills the stuck
  process after 1 hour of no progress.
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
    # Subscribe to encoding events instead of polling state
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())
    schedule_check()

    {:ok,
     %{
       encoding: false,
       video_id: nil,
       video_path: nil,
       last_progress_time: nil,
       last_progress_percent: nil,
       warned: false
     }}
  end

  # Handle encoding lifecycle events
  @impl true
  def handle_info({:encoding_started, data}, state) do
    now = System.monotonic_time(:millisecond)

    {:noreply,
     %{
       state
       | encoding: true,
         video_id: data[:video_id],
         video_path: data[:filename],
         last_progress_time: now,
         last_progress_percent: nil,
         warned: false
     }}
  end

  @impl true
  def handle_info({:encoding_progress, data}, state) do
    now = System.monotonic_time(:millisecond)
    percent = data[:percent]

    {:noreply,
     %{
       state
       | last_progress_time: now,
         last_progress_percent: percent,
         warned: false
     }}
  end

  @impl true
  def handle_info({:encoding_completed, _data}, state) do
    {:noreply,
     %{
       state
       | encoding: false,
         video_id: nil,
         video_path: nil,
         last_progress_time: nil,
         last_progress_percent: nil,
         warned: false
     }}
  end

  # Periodic health check
  @impl true
  def handle_info(:health_check, state) do
    new_state = perform_health_check(state)
    schedule_check()
    {:noreply, new_state}
  end

  # Ignore other PubSub events
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp perform_health_check(%{encoding: false} = state), do: state

  defp perform_health_check(%{encoding: true, last_progress_time: nil} = state) do
    # Encoding but no progress time set - initialize it
    %{state | last_progress_time: System.monotonic_time(:millisecond)}
  end

  defp perform_health_check(%{encoding: true} = state) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.last_progress_time

    cond do
      # Stuck for 1 hour - kill the process
      elapsed > @kill_threshold ->
        kill_stuck_encoder(state)
        %{state | encoding: false, last_progress_time: nil, warned: false}

      # Stuck for 30 min - warn
      elapsed > @warn_threshold and not state.warned ->
        warn_stuck_encoder(state)
        %{state | warned: true}

      true ->
        state
    end
  end

  defp warn_stuck_encoder(state) do
    Logger.warning(
      "Encoder may be stuck - no progress for 30+ minutes. " <>
        "Video ID: #{state.video_id}, Path: #{state.video_path}"
    )

    Events.broadcast_event(:encoder_health_alert, %{
      reason: :stalled_30_min,
      video_id: state.video_id,
      video_path: state.video_path
    })
  end

  defp kill_stuck_encoder(state) do
    # Only place we need to access encoder state - to get the port for killing
    case get_encoder_port() do
      {:ok, port} ->
        case Port.info(port, :os_pid) do
          {:os_pid, pid} ->
            Logger.error(
              "Killing stuck encoder process (PID: #{pid}) after 1 hour of no progress. " <>
                "Video ID: #{state.video_id}, Path: #{state.video_path}"
            )

            System.cmd("kill", [to_string(pid)])

            Events.broadcast_event(:encoder_health_alert, %{
              reason: :killed_stuck_process,
              video_id: state.video_id,
              video_path: state.video_path,
              os_pid: pid
            })

          _ ->
            Logger.error("Could not get OS PID for stuck encoder port")
        end

      :error ->
        Logger.error("Could not access encoder state to kill stuck process")
    end
  end

  defp get_encoder_port do
    case GenServer.whereis(Reencodarr.AbAv1.Encode) do
      nil ->
        :error

      pid ->
        try do
          state = :sys.get_state(pid)
          if state.port != :none, do: {:ok, state.port}, else: :error
        catch
          :exit, _ -> :error
        end
    end
  end

  defp schedule_check, do: Process.send_after(self(), :health_check, @check_interval)
end
