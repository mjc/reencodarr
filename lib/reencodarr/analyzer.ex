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
  but now triggers the Broadway pipeline to check for videos needing analysis.
  """
  @spec process_path(map()) :: :ok
  def process_path(%{path: path} = _video_info) do
    Logger.debug("🎭 Processing video path: #{path}")

    case Broadway.dispatch_available() do
      {:error, :producer_supervisor_not_found} ->
        Logger.error("Producer supervisor not found, cannot trigger dispatch")
        :ok

      _ ->
        :ok
    end
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
      service_type: to_string(service_type)
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
