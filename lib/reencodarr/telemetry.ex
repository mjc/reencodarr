defmodule Reencodarr.Telemetry do
  @moduledoc """
  Telemetry integration for Reencodarr.
  """

  require Logger

  def emit_encoder_started(filename) do
    safe_telemetry_execute(
      [:reencodarr, :encoder, :started],
      %{},
      %{filename: filename}
    )
  end

  def emit_encoder_progress(progress) do
    # Convert to map but keep all values - the reporter will handle merging
    measurements = Map.from_struct(progress)

    safe_telemetry_execute(
      [:reencodarr, :encoder, :progress],
      measurements,
      %{}
    )
  end

  def emit_encoder_completed do
    safe_telemetry_execute(
      [:reencodarr, :encoder, :completed],
      %{},
      %{}
    )
  end

  def emit_encoder_paused do
    safe_telemetry_execute(
      [:reencodarr, :encoder, :paused],
      %{},
      %{}
    )
  end

  def emit_encoder_failed(exit_code, video) do
    safe_telemetry_execute(
      [:reencodarr, :encoder, :failed],
      %{exit_code: exit_code},
      %{video: video}
    )
  end

  def emit_crf_search_started do
    safe_telemetry_execute(
      [:reencodarr, :crf_search, :started],
      %{},
      %{}
    )
  end

  def emit_crf_search_progress(progress) do
    # Convert to map but keep all values - the reporter will handle merging
    measurements = Map.from_struct(progress)

    safe_telemetry_execute(
      [:reencodarr, :crf_search, :progress],
      measurements,
      %{}
    )
  end

  def emit_crf_search_completed do
    safe_telemetry_execute(
      [:reencodarr, :crf_search, :completed],
      %{},
      %{}
    )
  end

  def emit_crf_search_paused do
    safe_telemetry_execute(
      [:reencodarr, :crf_search, :paused],
      %{},
      %{}
    )
  end

  def emit_sync_started(service_type \\ nil) do
    Logger.info("Telemetry: Emitting sync started event - service_type: #{service_type}")

    safe_telemetry_execute(
      [:reencodarr, :sync, :started],
      %{},
      %{service_type: service_type}
    )
  end

  def emit_sync_progress(progress, service_type \\ nil) do
    safe_telemetry_execute(
      [:reencodarr, :sync, :progress],
      %{progress: progress},
      %{service_type: service_type}
    )
  end

  def emit_sync_completed(service_type \\ nil) do
    safe_telemetry_execute(
      [:reencodarr, :sync, :completed],
      %{},
      %{service_type: service_type}
    )
  end

  def emit_sync_failed(error, service_type \\ nil) do
    safe_telemetry_execute(
      [:reencodarr, :sync, :failed],
      %{},
      %{error: error, service_type: service_type}
    )
  end

  def emit_video_upserted(video) do
    safe_telemetry_execute(
      [:reencodarr, :media, :video_upserted],
      %{},
      %{video: video}
    )
  end

  def emit_vmaf_upserted(vmaf) do
    safe_telemetry_execute(
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

    safe_telemetry_execute(
      [:reencodarr, :analyzer, :throughput],
      measurements,
      %{}
    )
  end

  def emit_crf_search_throughput(success_count, error_count) do
    safe_telemetry_execute(
      [:reencodarr, :crf_search, :throughput],
      %{success_count: success_count, error_count: error_count},
      %{}
    )
  end

  def emit_analyzer_started do
    safe_telemetry_execute(
      [:reencodarr, :analyzer, :started],
      %{},
      %{}
    )
  end

  def emit_analyzer_paused do
    safe_telemetry_execute(
      [:reencodarr, :analyzer, :paused],
      %{},
      %{}
    )
  end

  # Helper function to safely execute telemetry events
  defp safe_telemetry_execute(event, measurements, metadata) do
    if telemetry_ready?() do
      :telemetry.execute(event, measurements, metadata)
    else
      Logger.debug("Telemetry not ready for event: #{inspect(event)}")
      :ok
    end
  end

  # Check if telemetry system is ready by verifying the telemetry table exists
  defp telemetry_ready? do
    case :ets.whereis(:telemetry_handler_table) do
      :undefined -> false
      _tid -> true
    end
  end
end
