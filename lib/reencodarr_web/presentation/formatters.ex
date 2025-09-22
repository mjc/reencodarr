defmodule ReencodarrWeb.Presentation.Formatters do
  @moduledoc """
  Formatting utilities for the web interface.
  """

  @doc """
  Format file size in human readable format.
  """
  def format_file_size(nil), do: "Unknown"

  def format_file_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  @doc """
  Format bitrate in human readable format.
  """
  def format_bitrate(nil), do: "Unknown"

  def format_bitrate(bitrate) when is_integer(bitrate) do
    cond do
      bitrate >= 1_000_000 -> "#{Float.round(bitrate / 1_000_000, 1)} Mbps"
      bitrate >= 1000 -> "#{Float.round(bitrate / 1000, 1)} Kbps"
      true -> "#{bitrate} bps"
    end
  end

  @doc """
  Format duration in human readable format.
  """
  def format_duration(nil), do: "Unknown"

  def format_duration(seconds) when is_float(seconds) do
    total_seconds = round(seconds)
    hours = div(total_seconds, 3600)
    minutes = div(rem(total_seconds, 3600), 60)
    secs = rem(total_seconds, 60)

    if hours > 0 do
      "#{hours}h #{minutes}m"
    else
      "#{minutes}m #{secs}s"
    end
  end

  @doc """
  Format codec information.
  """
  def format_codec_info(video_codecs, audio_codecs)
      when is_list(video_codecs) and is_list(audio_codecs) do
    video = List.first(video_codecs) || "Unknown"
    audio = List.first(audio_codecs) || "Unknown"
    "#{video}/#{audio}"
  end

  def format_codec_info(_, _), do: "Unknown"

  @doc """
  Calculate percentage safely.
  """
  def safe_percentage(current, total)
      when is_integer(current) and is_integer(total) and total > 0 do
    round(current / total * 100)
  end

  def safe_percentage(_, _), do: 0

  @doc """
  Get progress field safely with default.
  """
  def progress_field(:none, _field, default), do: default

  def progress_field(progress, field, default) when is_map(progress) do
    Map.get(progress, field, default)
  end

  def progress_field(_, _field, default), do: default
end
