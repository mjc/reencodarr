defmodule Reencodarr.Telemetry do
  @moduledoc """
  Telemetry integration for Reencodarr.
  """

  require Logger

  def emit_encoder_started(filename) do
    execute_telemetry(
      [:reencodarr, :encoder, :started],
      %{},
      %{filename: filename}
    )
  end

  def emit_encoder_progress(progress) do
    # Convert to map but keep all values - the reporter will handle merging
    measurements = Map.from_struct(progress)

    execute_telemetry(
      [:reencodarr, :encoder, :progress],
      measurements,
      %{}
    )
  end

  def emit_encoder_completed do
    execute_telemetry(
      [:reencodarr, :encoder, :completed],
      %{},
      %{}
    )
  end

  def emit_encoder_paused do
    execute_telemetry(
      [:reencodarr, :encoder, :paused],
      %{},
      %{}
    )
  end

  def emit_encoder_failed(exit_code, video) do
    execute_telemetry(
      [:reencodarr, :encoder, :failed],
      %{exit_code: exit_code},
      %{video: video}
    )
  end

  def emit_crf_search_started do
    execute_telemetry(
      [:reencodarr, :crf_search, :started],
      %{},
      %{}
    )
  end

  def emit_crf_search_progress(progress) do
    # Convert to map but keep all values - the reporter will handle merging
    measurements = Map.from_struct(progress)

    execute_telemetry(
      [:reencodarr, :crf_search, :progress],
      measurements,
      %{}
    )
  end

  def emit_crf_search_completed do
    execute_telemetry(
      [:reencodarr, :crf_search, :completed],
      %{},
      %{}
    )
  end

  def emit_crf_search_paused do
    execute_telemetry(
      [:reencodarr, :crf_search, :paused],
      %{},
      %{}
    )
  end

  def emit_sync_started(service_type \\ nil) do
    Logger.info("Telemetry: Emitting sync started event - service_type: #{service_type}")

    execute_telemetry(
      [:reencodarr, :sync, :started],
      %{},
      %{service_type: service_type}
    )

    # Also broadcast to Dashboard V2
    alias Reencodarr.Dashboard.Events
    Events.broadcast_event(:sync_started, %{service_type: service_type})
  end

  def emit_sync_progress(progress, service_type \\ nil) do
    execute_telemetry(
      [:reencodarr, :sync, :progress],
      %{progress: progress},
      %{service_type: service_type}
    )

    # Also broadcast to Dashboard V2
    alias Reencodarr.Dashboard.Events
    Events.broadcast_event(:sync_progress, %{progress: progress, service_type: service_type})
  end

  def emit_sync_completed(service_type \\ nil) do
    execute_telemetry(
      [:reencodarr, :sync, :completed],
      %{},
      %{service_type: service_type}
    )

    # Also broadcast to Dashboard V2
    alias Reencodarr.Dashboard.Events
    Events.broadcast_event(:sync_completed, %{service_type: service_type})
  end

  def emit_sync_failed(error, service_type \\ nil) do
    execute_telemetry(
      [:reencodarr, :sync, :failed],
      %{},
      %{error: error, service_type: service_type}
    )

    # Also broadcast to Dashboard V2
    alias Reencodarr.Dashboard.Events
    Events.broadcast_event(:sync_failed, %{error: error, service_type: service_type})
  end

  def emit_video_upserted(video) do
    execute_telemetry(
      [:reencodarr, :media, :video_upserted],
      %{},
      %{video: video}
    )
  end

  def emit_vmaf_upserted(vmaf) do
    execute_telemetry(
      [:reencodarr, :media, :vmaf_upserted],
      %{},
      %{vmaf: vmaf}
    )
  end

  def emit_analyzer_throughput(throughput, queue_length, rate_limit \\ nil, batch_size \\ nil) do
    measurements = %{throughput: throughput, queue_length: queue_length}

    # Add performance data if provided
    measurements =
      if rate_limit && batch_size do
        Map.merge(measurements, %{rate_limit: rate_limit, batch_size: batch_size})
      else
        measurements
      end

    execute_telemetry(
      [:reencodarr, :analyzer, :throughput],
      measurements,
      %{}
    )
  end

  def emit_crf_search_throughput(success_count, error_count) do
    execute_telemetry(
      [:reencodarr, :crf_search, :throughput],
      %{success_count: success_count, error_count: error_count},
      %{}
    )
  end

  def emit_analyzer_started do
    execute_telemetry(
      [:reencodarr, :analyzer, :started],
      %{},
      %{}
    )
  end

  def emit_analyzer_paused do
    execute_telemetry(
      [:reencodarr, :analyzer, :paused],
      %{},
      %{}
    )
  end

  # Helper function to execute telemetry events with readiness check
  defp execute_telemetry(event, measurements, metadata) do
    if telemetry_ready?() do
      :telemetry.execute(event, measurements, metadata)
    else
      Logger.debug("Telemetry not ready for event: #{inspect(event)}")
    end

    :ok
  end

  # Check if telemetry system is ready by verifying the telemetry table exists
  defp telemetry_ready? do
    case :ets.whereis(:telemetry_handler_table) do
      :undefined -> false
      _tid -> true
    end
  end
end
