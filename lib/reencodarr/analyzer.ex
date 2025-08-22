defmodule Reencodarr.Analyzer do
  @moduledoc """
  Simplified compatibility layer for Broadway analyzer operations.
  
  Provides a clean API that delegates directly to Broadway modules without
  complex compatibility overhead.
  """

  alias Reencodarr.Analyzer.Broadway

  @doc """
  Process a video path by triggering Broadway dispatch.
  """
  @spec process_path(map()) :: :ok
  def process_path(%{path: _path} = _video_info) do
    case Broadway.dispatch_available() do
      {:error, :producer_supervisor_not_found} -> :ok
      _ -> :ok
    end
  end

  @doc """
  Re-analyze a video by ID.
  """
  def reanalyze_video(video_id) do
    %{path: path, service_id: service_id, service_type: service_type} =
      Reencodarr.Media.get_video!(video_id)

    process_path(%{
      path: path,
      service_id: service_id,
      service_type: to_string(service_type)
    })
  end

  @doc """
  Start the analyzer.
  """
  def start, do: Broadway.resume()

  @doc """
  Pause the analyzer.
  """
  def pause, do: Broadway.pause()

  @doc """
  Check if the analyzer is running.
  """
  def running?, do: Broadway.running?()
end
