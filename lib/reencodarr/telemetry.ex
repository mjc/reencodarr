defmodule Reencodarr.Telemetry do
  @moduledoc """
  Telemetry integration for Reencodarr.
  """

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

  def emit_sync_started do
    :telemetry.execute(
      [:reencodarr, :sync, :started],
      %{},
      %{}
    )
  end

  def emit_sync_progress(progress) do
    :telemetry.execute(
      [:reencodarr, :sync, :progress],
      %{progress: progress},
      %{}
    )
  end

  def emit_sync_completed do
    :telemetry.execute(
      [:reencodarr, :sync, :completed],
      %{},
      %{}
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
end
