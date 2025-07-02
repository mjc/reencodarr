defmodule Reencodarr.CrfSearcher.Consumer do
  @moduledoc """
  GenStage consumer for processing CRF search operations.

  This consumer subscribes to the CrfSearcher.Producer and processes videos
  by initiating CRF searches using the base consumer pattern.
  """

  use Reencodarr.GenStage.BaseConsumer

  alias Reencodarr.AbAv1

  @impl Reencodarr.GenStage.BaseConsumer
  def process_item(video) do
    AbAv1.crf_search(video, 95)
    :ok
  end

  @impl Reencodarr.GenStage.BaseConsumer
  def completion_event_topic, do: "crf_search_events"

  @impl Reencodarr.GenStage.BaseConsumer
  def item_id(video), do: video.id

  @impl Reencodarr.GenStage.BaseConsumer
  def producer_module, do: Reencodarr.CrfSearcher.Producer

  @impl Reencodarr.GenStage.BaseConsumer
  def log_start(video) do
    Logger.info("Starting CRF search for #{video.path}")
    :ok
  end

  @impl Reencodarr.GenStage.BaseConsumer
  def log_completion(video_id, result) do
    case result do
      :success ->
        Logger.info("Completed CRF search for video #{video_id}")

      :skipped ->
        Logger.info("Skipped CRF search for video #{video_id} (already exists or reencoded)")

      {:error, exit_code} ->
        Logger.error("CRF search failed for video #{video_id} with exit code: #{exit_code}")
    end

    :ok
  end
end
