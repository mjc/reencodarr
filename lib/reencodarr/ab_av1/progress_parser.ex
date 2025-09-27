defmodule Reencodarr.AbAv1.ProgressParser do
  @moduledoc """
  Centralized progress parsing for ab-av1 output.

  Handles parsing of various progress-related lines from ab-av1 output
  and broadcasts dashboard events for UI updates.
  """

  require Logger
  alias Reencodarr.Core.Parsers
  alias Reencodarr.Dashboard.Events

  @doc """
  Processes a single line of ab-av1 output and emits telemetry if applicable.

  Note: Regex patterns are recompiled on every call for simplicity. This trades
  a small performance cost for cleaner, more maintainable code.

  Returns `:ok` regardless of whether the line matched any patterns.
  """
  @spec process_line(String.t(), map()) :: :ok
  def process_line(line, state) when is_binary(line) and is_map(state) do
    case parse_line(line, state) do
      {:encoding_start, _filename} ->
        :ok

      {:progress, progress} ->
        # Broadcast to Dashboard Events system
        percent = progress.percent || 0
        video_id = if state.video, do: state.video.id, else: nil

        Events.broadcast_event(:encoding_progress, %{
          video_id: video_id,
          percent: percent,
          fps: progress.fps,
          eta: progress.eta,
          filename: progress.filename
        })

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

  # Cache patterns in process dictionary for performance
  # This avoids recompilation while maintaining Elixir 1.19 compatibility
  defp cached_patterns do
    case Process.get(:progress_parser_patterns) do
      nil ->
        patterns = %{
          encoding_start: ~r/\[.*\] encoding (?<filename>\d+\.mkv)/,
          # Main progress pattern with brackets: [timestamp] percent%, fps fps, eta time unit
          progress:
            ~r/\[(?<timestamp>[^\]]+)\].*?(?<percent>\d+(?:\.\d+)?)%,\s(?<fps>\d+(?:\.\d+)?)\sfps?,?\s?eta\s(?<eta>\d+)\s(?<time_unit>(?:second|minute|hour|day|week|month|year)s?)/,
          # Alternative progress pattern without brackets: percent%, fps fps, eta time unit or eta Unknown/N/A
          progress_alt:
            ~r/(?<percent>\d+(?:\.\d+)?)%,\s(?<fps>\d+(?:\.\d+)?)\sfps?,?\s?eta\s(?:(?<eta>\d+)\s(?<time_unit>(?:second|minute|hour|day|week|month|year)s?)|(?<eta_unknown>Unknown|N\/A|unknown))/,
          # File size progress pattern: Encoded X GB (percent%)
          file_size_progress: ~r/Encoded\s[\d.]+\s[KMGT]?B\s\((?<percent>\d+)%\)/
        }

        Process.put(:progress_parser_patterns, patterns)
        patterns

      patterns ->
        patterns
    end
  end

  defp parse_line(line, state) do
    # Access cached patterns for performance
    patterns = cached_patterns()

    cond do
      match = Regex.named_captures(patterns.encoding_start, line) ->
        handle_encoding_start(match, state)

      match = Regex.named_captures(patterns.progress, line) ->
        handle_progress(match, state)

      match = Regex.named_captures(patterns.progress_alt, line) ->
        handle_progress(match, state)

      match = Regex.named_captures(patterns.file_size_progress, line) ->
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
      |> Parsers.parse_int(0)

    filename = get_filename_for_encoding_start(state, video_id, filename_with_ext)

    {:encoding_start, filename}
  end

  defp handle_progress(match, state) do
    percent_str = match["percent"]
    fps_str = match["fps"]

    filename = if state.video, do: Path.basename(state.video.path), else: "unknown"

    # Handle both normal eta (number + time unit) and unknown eta
    eta =
      case {match["eta"], match["time_unit"], match["eta_unknown"]} do
        {eta_str, time_unit, nil} when eta_str != nil and time_unit != nil ->
          "#{eta_str} #{time_unit}"

        {nil, nil, eta_unknown} when eta_unknown != nil ->
          eta_unknown

        _ ->
          "unknown"
      end

    progress = %{
      filename: filename,
      percent: Parsers.parse_int(percent_str, 0),
      fps: parse_fps(fps_str),
      eta: eta
    }

    {:progress, progress}
  end

  defp handle_file_size_progress(%{"percent" => percent_str}, state) do
    filename = if state.video, do: Path.basename(state.video.path), else: "unknown"

    progress = %{
      filename: filename,
      percent: Parsers.parse_int(percent_str, 0),
      # File size progress doesn't include FPS
      fps: 0.0,
      # File size progress doesn't include ETA
      eta: "unknown"
    }

    {:progress, progress}
  end

  # Parse FPS and round to integer for consistency with tests
  defp parse_fps(fps_str) do
    case Parsers.parse_float_exact(fps_str) do
      {:ok, fps_float} ->
        # Round to nearest integer as a float (e.g., 23.5 -> 24.0)
        Float.round(fps_float)

      {:error, _} ->
        0.0
    end
  end

  defp get_filename_for_encoding_start(state, video_id, filename_with_ext) do
    if state.video && state.video.id == video_id do
      # Get the latest video data from database to handle updated paths
      case Reencodarr.Repo.get(Reencodarr.Media.Video, video_id) do
        %{path: path} when is_binary(path) -> Path.basename(path)
        _ -> get_fallback_filename(state)
      end
    else
      filename_with_ext
    end
  end

  defp get_fallback_filename(state) do
    if state.video, do: Path.basename(state.video.path), else: "unknown"
  end
end
