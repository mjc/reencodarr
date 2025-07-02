defmodule Reencodarr.ProgressParser do
  @moduledoc """
  Parses encoding progress output and emits telemetry events.

  This module handles the parsing of ab-av1 output lines and converts them
  into structured progress data for the dashboard.
  """

  require Logger

alias Reencodarr.AbAv1.Helper
alias Reencodarr.{Media, Telemetry}

  @doc """
  Processes a single line of output from the encoding process.
  """
  @spec process_line(String.t(), map()) :: :ok
  def process_line(data, state) do
    cond do
      captures = Regex.named_captures(~r/\[.*\] encoding (?<filename>\d+\.mkv)/, data) ->
        handle_encoding_start(captures, state)

      captures =
          Regex.named_captures(
            ~r/\[.*\]\s+(?<percent>\d+)%\s*,\s*(?<fps>[\d\.]+)\s*fps,\s*eta\s*(?<eta>\d+)\s*(?<unit>minutes|seconds|hours|days|weeks|months|years)/,
            data
          ) ->
        handle_progress_update(captures, state)

      _captures =
          Regex.named_captures(~r/Encoded\s(?<size>[\d\.]+\s\w+)\s\((?<percent>\d+)%\)/, data) ->
        # File size progress - not doing anything specific here currently
        :ok

      true ->
        # Non-matching lines are ignored
        :ok
    end
  end

  # Handles the start of encoding for a specific file.
  @spec handle_encoding_start(map(), map()) :: :ok
  defp handle_encoding_start(%{"filename" => filename}, _state) do
    file = filename
    extname = Path.extname(file)
    id = String.to_integer(Path.basename(file, extname))

    video = Media.get_video!(id)
    video_filename = video.path |> Path.basename()

    # Emit telemetry event for encoding start
    Telemetry.emit_encoder_started(video_filename)
    :ok
  end

  # Handles progress updates during encoding.
  @spec handle_progress_update(map(), map()) :: :ok
  defp handle_progress_update(captures, state) do
    %{
      "percent" => percent_str,
      "fps" => fps_str,
      "eta" => eta_str,
      "unit" => unit
    } = captures

    _eta_seconds = Helper.convert_to_seconds(String.to_integer(eta_str), unit)
    human_readable_eta = "#{eta_str} #{unit}"
    filename = Path.basename(state.video.path)

    # Create progress struct
    progress = %Reencodarr.Statistics.EncodingProgress{
      percent: String.to_integer(percent_str),
      eta: human_readable_eta,
      fps: parse_fps(fps_str),
      filename: filename
    }

    # Emit telemetry event for progress
    Telemetry.emit_encoder_progress(progress)
    :ok
  end

  # Parses FPS string to float, handling missing decimal points.
  @spec parse_fps(String.t()) :: float()
  defp parse_fps(fps_string) do
    fps_string
    |> then(fn str ->
      if String.contains?(str, ".") do
        str
      else
        str <> ".0"
      end
    end)
    |> String.to_float()
    |> Float.round()
  end
end
