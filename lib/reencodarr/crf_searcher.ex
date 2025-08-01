defmodule Reencodarr.CrfSearcher do
  @moduledoc """
  CrfSearcher module that uses Broadway for processing CRF search operations.
  """
  require Logger

  alias Reencodarr.CrfSearcher.Broadway
  alias Reencodarr.CrfSearcher.Broadway.Producer
  alias Reencodarr.Media

  @doc """
  Process a video for CRF search using the Broadway pipeline.
  """
  @spec process_video(map()) :: :ok
  def process_video(video) do
    Logger.debug("🔍 Processing video for CRF search: #{video.path}")
    Broadway.process_video(video)
    :ok
  end

  @doc """
  Check if the CRF searcher is running.
  """
  @spec running? :: boolean()
  def running? do
    Broadway.running?()
  end

  @doc """
  Start the CRF searcher.
  """
  @spec start :: :ok
  def start do
    Logger.info("🔍 Starting CRF searcher")
    Broadway.start()
    Producer.dispatch_available()
    :ok
  end

  @doc """
  Pause the CRF searcher.
  """
  @spec pause :: :ok
  def pause do
    Logger.info("🔍 Pausing CRF searcher")
    Broadway.pause()
    :ok
  end

  @doc """
  Resume the CRF searcher.
  """
  @spec resume :: :ok
  def resume do
    Logger.info("🔍 Resuming CRF searcher")
    Broadway.resume()
    :ok
  end

  @doc """
  Perform a CRF search on a video by ID.
  """
  def crf_search_video(video_id) do
    Logger.info("🔍 Starting CRF search for video with ID: #{video_id}")

    video = Media.get_video!(video_id)
    Logger.info("🔍 Found video at path: #{video.path}")

    process_video(video)
  end

  @doc """
  Dispatch available videos for processing.
  """
  def dispatch_available do
    Producer.dispatch_available()
  end
end
