defmodule Reencodarr.Dashboard.Events do
  @moduledoc """
  Centralized PubSub event system for dashboard updates.

  Provides a clean 3-layer architecture:
  Service → Events.broadcast → LiveView subscription
  """

  @dashboard_channel "dashboard"

  @doc "Broadcast CRF search started event"
  def crf_search_started(video_id, video_path, target_vmaf) do
    broadcast(
      {:crf_search_started,
       %{
         video_id: video_id,
         filename: Path.basename(video_path),
         target_vmaf: target_vmaf
       }}
    )
  end

  @doc "Broadcast CRF search progress event"
  def crf_search_progress(video_id, progress_data) do
    broadcast(
      {:crf_search_progress,
       %{
         video_id: video_id,
         percent: progress_data.percent || 0,
         filename: progress_data.filename && Path.basename(progress_data.filename)
       }}
    )
  end

  @doc "Broadcast CRF search encoding sample event"
  def crf_search_encoding_sample(video_id, sample_data) do
    broadcast(
      {:crf_search_encoding_sample,
       %{
         video_id: video_id,
         filename: sample_data.filename && Path.basename(sample_data.filename),
         crf: sample_data.crf,
         sample_num: sample_data.sample_num,
         total_samples: sample_data.total_samples
       }}
    )
  end

  @doc "Broadcast CRF search VMAF result event"
  def crf_search_vmaf_result(video_path, vmaf_data) do
    broadcast(
      {:crf_search_vmaf_result,
       %{
         video_id: vmaf_data.video_id,
         filename: video_path && Path.basename(video_path),
         crf: vmaf_data.crf,
         score: vmaf_data.score
       }}
    )
  end

  @doc "Broadcast CRF search completed event"
  def crf_search_completed(video_id, result) do
    broadcast(
      {:crf_search_completed,
       %{
         video_id: video_id,
         result: result
       }}
    )
  end

  @doc "Broadcast encoding started event"
  def encoding_started(video_id, video_path) do
    broadcast(
      {:encoding_started,
       %{
         video_id: video_id,
         filename: Path.basename(video_path)
       }}
    )
  end

  @doc "Broadcast encoding progress event"
  def encoding_progress(video_id, percent, progress_data \\ %{}) do
    broadcast(
      {:encoding_progress,
       %{
         video_id: video_id,
         percent: percent,
         fps: Map.get(progress_data, :fps),
         eta: Map.get(progress_data, :eta),
         time_unit: Map.get(progress_data, :time_unit),
         timestamp: Map.get(progress_data, :timestamp)
       }}
    )
  end

  @doc "Broadcast encoding completed event"
  def encoding_completed(video_id, result) do
    broadcast(
      {:encoding_completed,
       %{
         video_id: video_id,
         result: result
       }}
    )
  end

  @doc "Broadcast analyzer progress event"
  def analyzer_progress(count, total) do
    percent = if total > 0, do: round(count / total * 100), else: 0

    broadcast(
      {:analyzer_progress,
       %{
         count: count,
         total: total,
         percent: percent
       }}
    )
  end

  @doc "Broadcast analyzer started event"
  def analyzer_started do
    broadcast({:analyzer_started, %{}})
  end

  @doc "Broadcast analyzer stopped event"
  def analyzer_stopped do
    broadcast({:analyzer_stopped, %{}})
  end

  @doc "Broadcast analyzer throughput event with performance metrics"
  def analyzer_throughput(throughput, queue_length, batch_size \\ nil) do
    broadcast(
      {:analyzer_throughput,
       %{
         throughput: throughput,
         queue_length: queue_length,
         batch_size: batch_size
       }}
    )
  end

  @doc "Get the dashboard channel name for subscriptions"
  def channel, do: @dashboard_channel

  # Private helper to broadcast events
  defp broadcast(message) do
    Phoenix.PubSub.broadcast(
      Reencodarr.PubSub,
      @dashboard_channel,
      message
    )
  end
end
