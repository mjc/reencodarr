defmodule Reencodarr.AbAv1.ProgressParser do
  @moduledoc """
  Centralized progress parsing for ab-av1 output.

  Handles parsing of various progress-related lines from ab-av1 output
  and emits appropriate telemetry events.
  """

  require Logger
  alias Reencodarr.Statistics.EncodingProgress
  alias Reencodarr.Telemetry

  # Pattern definitions for parsing progress lines
  @patterns %{
    encoding_start: ~r/\[.*\] encoding (?<filename>\d+\.mkv)/,
    # Main progress pattern with brackets: [timestamp] percent%, fps fps, eta time unit
    progress:
      ~r/\[(?<timestamp>[^\]]+)\].*?(?<percent>\d+(?:\.\d+)?)%,\s(?<fps>\d+(?:\.\d+)?)\sfps?,?\s?eta\s(?<eta>\d+)\s(?<time_unit>(?:second|minute|hour|day|week|month|year)s?)/,
    # Alternative progress pattern without brackets: percent%, fps fps, eta time unit
    progress_alt:
      ~r/(?<percent>\d+(?:\.\d+)?)%,\s(?<fps>\d+(?:\.\d+)?)\sfps?,?\s?eta\s(?<eta>\d+)\s(?<time_unit>(?:second|minute|hour|day|week|month|year)s?)/,
    # File size progress pattern: Encoded X GB (percent%)
    file_size_progress: ~r/Encoded\s[\d.]+\s[KMGT]?B\s\((?<percent>\d+)%\)/
  }

  @doc """
  Processes a single line of ab-av1 output and emits telemetry if applicable.

  Returns `:ok` regardless of whether the line matched any patterns.
  """
  @spec process_line(String.t(), map()) :: :ok
  def process_line(line, state) when is_binary(line) and is_map(state) do
    case parse_line(line, state) do
      {:encoding_start, filename} ->
        Telemetry.emit_encoder_started(filename)
        :ok

      {:progress, progress} ->
        Telemetry.emit_encoder_progress(progress)
        :ok

      {:unmatched, line} ->
        # Only log warning for lines that look like progress but don't match our patterns
        if String.contains?(line, "%") do
          Logger.warning("ProgressParser: Unmatched encoding progress-like line: #{line}")
        end

        :ok
    end
  end

  # Private functions

  defp parse_line(line, state) do
    cond do
      match = Regex.named_captures(@patterns.encoding_start, line) ->
        handle_encoding_start(match, state)

      match = Regex.named_captures(@patterns.progress, line) ->
        handle_progress(match, state)

      match = Regex.named_captures(@patterns.progress_alt, line) ->
        handle_progress(match, state)

      match = Regex.named_captures(@patterns.file_size_progress, line) ->
        handle_file_size_progress(match, state)

      true ->
        {:unmatched, line}
    end
  end

  defp handle_encoding_start(%{"filename" => filename_with_ext}, state) do
    # Extract video ID from filename (e.g., "123.mkv" -> get original filename)
    video_id =
      filename_with_ext
      |> Path.basename(".mkv")
      |> String.to_integer()

    filename =
      if state.video.id == video_id do
        # Get the latest video data from database to handle updated paths
        case Reencodarr.Repo.get(Reencodarr.Media.Video, video_id) do
          %{path: path} when is_binary(path) -> Path.basename(path)
          _ -> Path.basename(state.video.path)
        end
      else
        filename_with_ext
      end

    {:encoding_start, filename}
  end

  defp handle_progress(match, state) do
    %{
      "percent" => percent_str,
      "fps" => fps_str,
      "eta" => eta_str,
      "time_unit" => time_unit
    } = match

    filename = Path.basename(state.video.path)

    progress = %EncodingProgress{
      filename: filename,
      percent: String.to_integer(percent_str),
      fps: parse_fps(fps_str),
      eta: "#{eta_str} #{time_unit}"
    }

    {:progress, progress}
  end

  defp handle_file_size_progress(%{"percent" => percent_str}, state) do
    filename = Path.basename(state.video.path)

    progress = %EncodingProgress{
      filename: filename,
      percent: String.to_integer(percent_str),
      fps: 0.0,  # File size progress doesn't include FPS
      eta: "unknown"  # File size progress doesn't include ETA
    }

    {:progress, progress}
  end

  # Parse FPS and round to integer for consistency with tests
  defp parse_fps(fps_str) do
    case Float.parse(fps_str) do
      {fps_float, _} ->
        # Round to nearest integer as a float (e.g., 23.5 -> 24.0)
        Float.round(fps_float)

      :error ->
        0.0
    end
  end
end
