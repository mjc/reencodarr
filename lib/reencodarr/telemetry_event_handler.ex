defmodule Reencodarr.TelemetryEventHandler do
  @moduledoc """
  Centralized telemetry event handling for the TelemetryReporter.

  This module contains all the telemetry event handler functions, making the
  TelemetryReporter module cleaner and the event handling logic more organized.
  """

  require Logger

  @doc """
  Handles all telemetry events for the TelemetryReporter.

  This function is attached to telemetry events and routes them to the
  appropriate handler based on the event name.
  """
  def handle_event(event_name, measurements, metadata, config)

  # Encoder events
  def handle_event([:reencodarr, :encoder, :started], _measurements, %{filename: filename}, %{
        reporter_pid: pid
      }) do
    GenServer.cast(pid, {:update_encoding, true, filename})
  end

  def handle_event([:reencodarr, :encoder, :progress], measurements, _metadata, %{
        reporter_pid: pid
      }) do
    GenServer.cast(pid, {:update_encoding_progress, measurements})
  end

  def handle_event([:reencodarr, :encoder, :completed], _measurements, _metadata, %{
        reporter_pid: pid
      }) do
    GenServer.cast(pid, {:update_encoding, false, :none})
  end

  def handle_event([:reencodarr, :encoder, :failed], measurements, metadata, %{reporter_pid: pid}) do
    Logger.warning("Encoding failed: #{inspect(measurements)} metadata: #{inspect(metadata)}")
    GenServer.cast(pid, {:update_encoding, false, :none})
  end

  def handle_event([:reencodarr, :encoder, :paused], _measurements, _metadata, %{
        reporter_pid: pid
      }) do
    GenServer.cast(pid, {:update_encoding, false, :none})
  end

  # CRF search events
  def handle_event([:reencodarr, :crf_search, :started], _measurements, _metadata, %{
        reporter_pid: pid
      }) do
    GenServer.cast(pid, {:update_crf_search, true})
  end

  def handle_event([:reencodarr, :crf_search, :progress], measurements, _metadata, %{
        reporter_pid: pid
      }) do
    GenServer.cast(pid, {:update_crf_search_progress, measurements})
  end

  def handle_event([:reencodarr, :crf_search, :completed], _measurements, _metadata, %{
        reporter_pid: pid
      }) do
    GenServer.cast(pid, {:update_crf_search, false})
  end

  def handle_event([:reencodarr, :crf_search, :paused], _measurements, _metadata, %{
        reporter_pid: pid
      }) do
    GenServer.cast(pid, {:update_crf_search, false})
  end

  # Analyzer events
  def handle_event([:reencodarr, :analyzer, :started], _measurements, _metadata, %{
        reporter_pid: pid
      }) do
    GenServer.cast(pid, {:update_analyzer, true})
  end

  def handle_event([:reencodarr, :analyzer, :paused], _measurements, _metadata, %{
        reporter_pid: pid
      }) do
    GenServer.cast(pid, {:update_analyzer, false})
  end

  # Sync events
  def handle_event([:reencodarr, :sync, event], measurements, metadata, %{reporter_pid: pid}) do
    service_type = Map.get(metadata, :service_type)
    GenServer.cast(pid, {:update_sync, event, measurements, service_type})
  end

  # Media events (trigger stats refresh)
  def handle_event([:reencodarr, :media, _event], _measurements, _metadata, %{reporter_pid: pid}) do
    send(pid, :refresh_stats)
  end

  # Catch-all for unhandled events
  def handle_event(event, measurements, _metadata, _config) do
    Logger.debug(
      "TelemetryEventHandler: Unhandled event #{inspect(event)} - measurements: #{inspect(measurements)}"
    )

    :ok
  end

  @doc """
  Returns the list of telemetry events that should be handled.
  """
  def events do
    [
      [:reencodarr, :encoder, :started],
      [:reencodarr, :encoder, :progress],
      [:reencodarr, :encoder, :completed],
      [:reencodarr, :encoder, :failed],
      [:reencodarr, :encoder, :paused],
      [:reencodarr, :crf_search, :started],
      [:reencodarr, :crf_search, :progress],
      [:reencodarr, :crf_search, :completed],
      [:reencodarr, :crf_search, :paused],
      [:reencodarr, :analyzer, :started],
      [:reencodarr, :analyzer, :paused],
      [:reencodarr, :sync, :started],
      [:reencodarr, :sync, :progress],
      [:reencodarr, :sync, :completed],
      [:reencodarr, :media, :video_upserted],
      [:reencodarr, :media, :vmaf_upserted]
    ]
  end
end
