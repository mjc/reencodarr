defmodule Reencodarr.Telemetry do
  @moduledoc """
  Telemetry integration for Reencodarr.
  """

  require Logger

  def emit_encoder_started(filename) do
    :telemetry.execute(
      [:reencodarr, :encoder, :started],
      %{},
      %{filename: filename}
    )
  end

  def emit_encoder_progress(progress) do
    # Convert to map but keep all values - the reporter will handle merging
    measurements = Map.from_struct(progress)

    :telemetry.execute(
      [:reencodarr, :encoder, :progress],
      measurements,
      %{}
    )
  end

  def emit_encoder_completed do
    :telemetry.execute(
      [:reencodarr, :encoder, :completed],
      %{},
      %{}
    )
  end

  def emit_encoder_failed(exit_code, video) do
    :telemetry.execute(
      [:reencodarr, :encoder, :failed],
      %{exit_code: exit_code},
      %{video: video}
    )
  end

  def emit_crf_search_started do
    :telemetry.execute(
      [:reencodarr, :crf_search, :started],
      %{},
      %{}
    )
  end

  def emit_crf_search_progress(progress) do
    # Convert to map but keep all values - the reporter will handle merging
    measurements = Map.from_struct(progress)

    :telemetry.execute(
      [:reencodarr, :crf_search, :progress],
      measurements,
      %{}
    )
  end

  def emit_crf_search_completed do
    :telemetry.execute(
      [:reencodarr, :crf_search, :completed],
      %{},
      %{}
    )
  end

  def emit_sync_started(service_type \\ nil) do
    Logger.info("Telemetry: Emitting sync started event - service_type: #{service_type}")

    :telemetry.execute(
      [:reencodarr, :sync, :started],
      %{},
      %{service_type: service_type}
    )
  end

  def emit_sync_progress(progress, service_type \\ nil) do
    :telemetry.execute(
      [:reencodarr, :sync, :progress],
      %{progress: progress},
      %{service_type: service_type}
    )
  end

  def emit_sync_completed(service_type \\ nil) do
    :telemetry.execute(
      [:reencodarr, :sync, :completed],
      %{},
      %{service_type: service_type}
    )
  end

  def emit_video_upserted(video) do
    :telemetry.execute(
      [:reencodarr, :media, :video_upserted],
      %{},
      %{video: video}
    )
  end

  def emit_vmaf_upserted(vmaf) do
    :telemetry.execute(
      [:reencodarr, :media, :vmaf_upserted],
      %{},
      %{vmaf: vmaf}
    )
  end

  def emit_analyzer_throughput(throughput, queue_length) do
    :telemetry.execute(
      [:reencodarr, :analyzer, :throughput],
      %{throughput: throughput, queue_length: queue_length},
      %{}
    )
  end

  def emit_crf_search_throughput(success_count, error_count) do
    :telemetry.execute(
      [:reencodarr, :crf_search, :throughput],
      %{success_count: success_count, error_count: error_count},
      %{}
    )
  end
end
