defmodule Reencodarr.CrfSearcher do
  @moduledoc """
  Public API for the CRF Searcher pipeline.

  Provides convenient functions for controlling and monitoring the CRF searcher
  Broadway pipeline that performs VMAF quality targeting searches on analyzed videos.
  """

  alias Reencodarr.CrfSearcher.Broadway
  alias Reencodarr.Media

  # Control functions

  @doc "Start/resume the CRF searcher pipeline"
  def start, do: Broadway.resume()

  @doc "Pause the CRF searcher pipeline"
  def pause, do: Broadway.pause()

  @doc "Resume the CRF searcher pipeline (alias for start)"
  def resume, do: Broadway.resume()

  @doc "Force dispatch of available work (no-op with new simple design)"
  def dispatch_available, do: :ok

  @doc "Queue a video for CRF search (no-op - videos pulled from DB automatically)"
  def queue_video(_video), do: :ok

  # Status functions

  @doc "Check if the CRF searcher is running"
  def running?, do: Broadway.running?()

  @doc "Check if the CRF searcher is actively processing work"
  def actively_running?, do: Broadway.running?()

  @doc "Check if the CRF search GenServer is available"
  def available? do
    case GenServer.whereis(Reencodarr.AbAv1.CrfSearch) do
      nil -> false
      pid when is_pid(pid) -> Process.alive?(pid)
    end
  end

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
