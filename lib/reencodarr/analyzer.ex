defmodule Reencodarr.Analyzer do
  @moduledoc """
  Public API for the Analyzer pipeline.

  Provides convenient functions for controlling and monitoring the analyzer
  Broadway pipeline that processes video files for MediaInfo analysis.
  """

  alias Reencodarr.Analyzer.Broadway.Producer
  alias Reencodarr.Media

  # Control functions

  @doc "Start/resume the analyzer pipeline"
  def start, do: Producer.resume()

  @doc "Pause the analyzer pipeline"
  def pause, do: Producer.pause()

  @doc "Resume the analyzer pipeline (alias for start)"
  def resume, do: Producer.resume()

  @doc "Force dispatch of available work"
  def dispatch_available, do: Producer.dispatch_available()

  @doc "Queue a video for analysis (typically called by sync process)"
  def queue_video(video_info), do: Producer.add_video(video_info)

  # Status functions

  @doc "Check if the analyzer is running (user intent)"
  def running?, do: Producer.running?()

  @doc "Check if the analyzer is actively processing work"
  def actively_running?, do: Producer.actively_running?()

  @doc "Get the current state of the analyzer pipeline"
  def status do
    %{
      running: running?(),
      actively_running: actively_running?(),
      queue_count: Media.count_videos_needing_analysis()
    }
  end

  # Queue management

  @doc "Get count of videos needing analysis"
  def queue_count, do: Media.count_videos_needing_analysis()

  @doc "Get next videos in the analysis queue"
  def next_videos(limit \\ 10), do: Media.get_videos_needing_analysis(limit)
end
