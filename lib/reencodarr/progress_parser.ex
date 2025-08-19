defmodule Reencodarr.ProgressParser do
  @moduledoc """
  Parses encoding progress output and emits telemetry events.

  This module handles the parsing of ab-av1 output lines and converts them
  into structured progress data for the dashboard. Now uses the centralized
  AbAv1.OutputParser for consistent parsing.
  """

  require Logger

  alias Reencodarr.AbAv1.OutputParser
  alias Reencodarr.{Core.Time, Media, Telemetry}

  @doc """
  Processes a single line of output from the encoding process.
  """
  @spec process_line(String.t(), map()) :: :ok
  def process_line(data, state) do
    case OutputParser.parse_line(data) do
      {:ok, %{type: :encoding_start, data: parsed_data}} ->
        handle_encoding_start(parsed_data, state)

      {:ok, %{type: :encoding_progress, data: parsed_data}} ->
        handle_progress_update(parsed_data, state)

      {:ok, %{type: :progress, data: parsed_data}} ->
        # Transform :progress data to match expected format
        transformed_data = %{
          percent: Map.get(parsed_data, :progress),
          fps: Map.get(parsed_data, :fps),
          eta: Map.get(parsed_data, :eta),
          eta_unit: Map.get(parsed_data, :eta_unit)
        }

        handle_progress_update(transformed_data, state)

      {:ok, %{type: :file_size_progress, data: _parsed_data}} ->
        # File size progress - not doing anything specific here currently
        :ok

      :ignore ->
        # Check for any line containing percentage, fps, or eta that we might have missed
        if String.contains?(data, "%") or String.contains?(data, "fps") or
             String.contains?(data, "eta") do
          Logger.warning("ProgressParser: Unmatched progress-like line: #{inspect(data)}")
        end

        :ok
    end
  end

  # Handles the start of encoding for a specific file.
  @spec handle_encoding_start(map(), map()) :: :ok
  defp handle_encoding_start(%{video_id: video_id}, _state) when is_integer(video_id) do
    video = Media.get_video!(video_id)
    video_filename = video.path |> Path.basename()

    # Emit telemetry event for encoding start
    Telemetry.emit_encoder_started(video_filename)
    :ok
  end

  # Fallback for cases where video_id cannot be parsed from the encoding start line
  defp handle_encoding_start(parsed_data, state) do
    Logger.debug(
      "ProgressParser: Could not extract video_id from encoding start data: #{inspect(parsed_data)}"
    )

    # Use the video from the current state instead
    video_filename = Path.basename(state.video.path)

    # Emit telemetry event for encoding start
    Telemetry.emit_encoder_started(video_filename)
    :ok
  end

  # Handles progress updates during encoding.
  @spec handle_progress_update(map(), map()) :: :ok
  defp handle_progress_update(%{percent: percent, fps: fps, eta: eta, eta_unit: unit}, state) do
    _eta_seconds = Time.to_seconds(eta, unit)
    human_readable_eta = format_eta(eta, unit)
    filename = Path.basename(state.video.path)

    # Create progress struct
    progress = %Reencodarr.Statistics.EncodingProgress{
      percent: percent,
      eta: human_readable_eta,
      fps: Float.round(fps),
      filename: filename
    }

    # Emit telemetry event for progress
    Telemetry.emit_encoder_progress(progress)
    :ok
  end

  # Fallback for cases where progress data cannot be fully parsed
  defp handle_progress_update(parsed_data, state) do
    Logger.debug(
      "ProgressParser: Could not extract complete progress data: #{inspect(parsed_data)}"
    )

    # Try to emit basic progress with whatever data we have
    filename = Path.basename(state.video.path)

    basic_progress = %Reencodarr.Statistics.EncodingProgress{
      percent: Map.get(parsed_data, :percent, 0),
      eta: "unknown",
      fps: Map.get(parsed_data, :fps, 0.0) |> Float.round(),
      filename: filename
    }

    # Emit telemetry event for basic progress
    Telemetry.emit_encoder_progress(basic_progress)
    :ok
  end

  # Helper function to format ETA with proper pluralization
  defp format_eta(eta, unit) when eta == 1, do: "#{eta} #{unit}"

  defp format_eta(eta, unit) do
    # If unit already ends with 's', don't add another 's'
    if String.ends_with?(unit, "s") do
      "#{eta} #{unit}"
    else
      "#{eta} #{unit}s"
    end
  end
end
