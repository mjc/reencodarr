defmodule Reencodarr.CrfSearcher do
  @moduledoc """
  Public API for the CRF Searcher pipeline.

  Provides convenient functions for controlling and monitoring the CRF searcher
  Broadway pipeline that performs VMAF quality targeting searches on analyzed videos.
  """

  alias Reencodarr.AbAv1.CrfSearch
  alias Reencodarr.CrfSearcher.Broadway
  alias Reencodarr.Media

  # Control functions

  @doc "Start/resume the CRF searcher pipeline"
  def start, do: Broadway.resume()

  @doc "Pause the CRF searcher pipeline"
  def pause, do: Broadway.pause()

  @doc "Resume the CRF searcher pipeline (alias for start)"
  def resume, do: Broadway.resume()

  @doc "Suspend the active CRF search OS process and gate future dispatch"
  def suspend_current, do: CrfSearch.suspend_current()

  @doc "Resume the active CRF search OS process and ungate dispatch"
  def resume_current, do: CrfSearch.resume_current()

  @doc "Fail the active CRF search job"
  def fail_current, do: CrfSearch.fail_current()

  # Status functions

  @doc "Check if the CRF searcher is running"
  def running?, do: Broadway.running?()

  @doc "Check if the CRF searcher is actively processing work"
  def actively_running? do
    # Simple: if CrfSearch GenServer is busy, we're actively running
    available?() != :available
  end

  @doc "Check if the CRF search GenServer is available"
  def available?, do: CrfSearch.available?()

  @doc "Get the current state of the CRF searcher pipeline"
  def status do
    %{
      running: running?(),
      actively_running: actively_running?(),
      available: available?(),
      queue_count: Media.count_videos_for_crf_search()
    }
  end

  # Queue management

  @doc "Get count of videos needing CRF search"
  def queue_count, do: Media.count_videos_for_crf_search()

  @doc "Get next videos in the CRF search queue"
  def next_videos(limit \\ 10), do: Media.get_videos_for_crf_search(limit)
end
