defmodule Reencodarr.Analyzer do
  @moduledoc """
  Analyzer module that uses Broadway for processing video analysis.
  Provides backward compatibility with the old GenServer-based analyzer.
  """
  require Logger

  alias Reencodarr.Analyzer.Broadway
  alias Reencodarr.Telemetry

  @doc """
  Process a video path. This function maintains compatibility with the old API
  but now adds the video info to the Broadway pipeline.
  """
  @spec process_path(map()) :: :ok
  def process_path(%{path: path} = video_info) do
    Logger.debug("🎭 Processing video path: #{path}")

    # For force_reanalyze videos, add them directly to the producer's manual queue
    force_reanalyze = Map.get(video_info, :force_reanalyze, false)

    if force_reanalyze do
      Logger.debug("🎭 Force reanalyze requested for #{path}, adding to Broadway queue")
      Broadway.process_path(video_info)
    else
      # Normal videos will be picked up by the producer automatically when there's demand
      # We don't need to trigger dispatch - Broadway handles this via demand
      Logger.debug("🎭 Video will be processed when demand is available: #{path}")
    end

    :ok
  end

  @doc """
  Re-analyze a video by ID. This function maintains compatibility with the old API.
  """
  def reanalyze_video(video_id) do
    Logger.debug("🎭 Reanalyzing video with ID: #{video_id}")

    %{path: path, service_id: service_id, service_type: service_type} =
      Reencodarr.Media.get_video!(video_id)

    Logger.debug("🎭 Found video at path: #{path}")

    process_path(%{
      path: path,
      service_id: service_id,
      service_type: to_string(service_type),
      force_reanalyze: true
    })
  end

  @doc """
  Start the analyzer. This function maintains compatibility with the old API.
  """
  def start do
    Logger.debug("🎭 Starting analyzer")
    Broadway.resume()
    Telemetry.emit_analyzer_started()
  end

  @doc """
  Pause the analyzer. This function maintains compatibility with the old API.
  """
  def pause do
    Logger.debug("🎭 Pausing analyzer")
    Broadway.pause()
    Telemetry.emit_analyzer_paused()
  end

  @doc """
  Check if the analyzer is running.
  """
  def running? do
    Broadway.running?()
  end
end
