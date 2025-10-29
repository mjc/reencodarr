defmodule Reencodarr.Analyzer do
  @moduledoc """
  Public API for the Analyzer pipeline.
  """

  alias Reencodarr.Analyzer.Broadway.Producer
  alias Reencodarr.Media

  @doc "Force dispatch of available work"
  def dispatch_available, do: Producer.dispatch_available()

  @doc "Get the current state of the analyzer pipeline"
  def status do
    %{
      running: true,
      actively_running: false,
      queue_count: Media.count_videos_needing_analysis()
    }
  end

  # Queue management

  @doc "Get count of videos needing analysis"
  def queue_count, do: Media.count_videos_needing_analysis()

  @doc "Get next videos in the analysis queue"
  def next_videos(limit \\ 10), do: Media.get_videos_needing_analysis(limit)
end
