defmodule Reencodarr.Formatters do
  @moduledoc """
  Minimal, idiomatic formatting utilities for Reencodarr.
  """

  # === FILE SIZES ===

  @spec file_size(non_neg_integer()) :: String.t()
  def file_size(bytes) when is_integer(bytes) and bytes >= 0 do
    cond do
      bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776, 1)} TiB"
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GiB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MiB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KiB"
      true -> "#{bytes} B"
    end
  end

  @spec file_size(any()) :: String.t()
  def file_size(_), do: "N/A"

  @spec file_size_gib(pos_integer()) :: float()
  def file_size_gib(bytes) when is_integer(bytes) and bytes > 0 do
    Float.round(bytes / 1_073_741_824, 2)
  end

  @spec file_size_gib(any()) :: float()
  def file_size_gib(_), do: 0.0

  @spec savings_bytes(pos_integer()) :: String.t()
  def savings_bytes(bytes) when is_integer(bytes) and bytes > 0, do: file_size(bytes)

  @spec savings_bytes(any()) :: String.t()
  def savings_bytes(_), do: "N/A"

  # === COUNTS & NUMBERS ===

  @spec count(integer()) :: String.t()
  def count(count) when is_integer(count) do
    cond do
      count >= 1_000_000_000 ->
        "#{Float.round(count / 1_000_000_000, 1)}B"

      count >= 1_000_000 ->
        "#{Float.round(count / 1_000_000, 1)}M"

      count >= 1_000 ->
        # Special handling for values that round to 1000
        rounded = Float.round(count / 1_000, 1)

        if rounded >= 1000.0 do
          "1000.0K"
        else
          "#{rounded}K"
        end

      true ->
        to_string(count)
    end
  end

  @spec count(any()) :: String.t()
  def count(count), do: to_string(count)

  # === VIDEO METRICS ===

  @spec bitrate_mbps(pos_integer()) :: String.t()
  def bitrate_mbps(bitrate) when is_integer(bitrate) and bitrate > 0 do
    "#{Float.round(bitrate / 1_000_000, 1)} Mbps"
  end

  @spec bitrate_mbps(any()) :: String.t()
  def bitrate_mbps(_), do: "N/A"

  @spec bitrate(integer()) :: String.t()
  def bitrate(bitrate) when is_integer(bitrate) do
    cond do
      bitrate >= 1_000_000 -> "#{Float.round(bitrate / 1_000_000, 1)} Mbps"
      bitrate >= 1000 -> "#{Float.round(bitrate / 1000, 1)} Kbps"
      true -> "#{bitrate} bps"
    end
  end

  @spec bitrate(any()) :: String.t()
  def bitrate(_), do: "Unknown"

  @spec fps(number()) :: String.t()
  def fps(fps) when is_number(fps) do
    if fps == trunc(fps), do: "#{trunc(fps)} fps", else: "#{Float.round(fps, 1)} fps"
  end

  @spec fps(any()) :: String.t()
  def fps(fps), do: to_string(fps)

  @spec crf(any()) :: String.t()
  def crf(crf), do: to_string(crf)

  @spec vmaf_score(number()) :: String.t()
  def vmaf_score(score) when is_number(score), do: "#{Float.round(score / 1, 1)}"

  @spec vmaf_score(any()) :: String.t()
  def vmaf_score(score), do: to_string(score)

  @spec codec_info([String.t()], [String.t()]) :: String.t()
  def codec_info(video_codecs, audio_codecs)
      when is_list(video_codecs) and is_list(audio_codecs) do
    video = List.first(video_codecs) || "Unknown"
    audio = List.first(audio_codecs) || "Unknown"
    "#{video}/#{audio}"
  end

  @spec codec_info(any(), any()) :: String.t()
  def codec_info(_, _), do: "Unknown"

  # === TIME ===

  @spec duration(number()) :: String.t()
  def duration(seconds) when is_number(seconds) and seconds > 0 do
    hours = div(trunc(seconds), 3600)
    minutes = div(rem(trunc(seconds), 3600), 60)
    secs = rem(trunc(seconds), 60)

    cond do
      hours > 0 -> "#{hours}h #{minutes}m #{secs}s"
      minutes > 0 -> "#{minutes}m #{secs}s"
      true -> "#{secs}s"
    end
  end

  @spec duration(any()) :: String.t()
  def duration(_), do: "N/A"

  @spec eta(String.t()) :: String.t()
  def eta(eta) when is_binary(eta), do: eta

  @spec eta(number()) :: String.t()
  def eta(eta) when is_number(eta), do: duration(eta)

  @spec eta(any()) :: String.t()
  def eta(_), do: "N/A"

  @spec relative_time(DateTime.t()) :: String.t()
  def relative_time(%DateTime{} = datetime) do
    diff_seconds = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff_seconds < 60 -> "#{diff_seconds} seconds ago"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)} minutes ago"
      diff_seconds < 86_400 -> "#{div(diff_seconds, 3600)} hours ago"
      diff_seconds < 2_592_000 -> "#{div(diff_seconds, 86_400)} days ago"
      true -> "#{div(diff_seconds, 2_592_000)} months ago"
    end
  end

  @spec relative_time(NaiveDateTime.t()) :: String.t()
  def relative_time(%NaiveDateTime{} = datetime) do
    datetime |> DateTime.from_naive!("Etc/UTC") |> relative_time()
  end

  @spec relative_time(String.t()) :: String.t()
  def relative_time(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _} -> relative_time(dt)
      _ -> "Invalid date"
    end
  end

  @spec relative_time(any()) :: String.t()
  def relative_time(_), do: "Never"

  # === UTILITIES ===

  @spec filename(String.t()) :: String.t()
  def filename(path) when is_binary(path) do
    basename = Path.basename(path, Path.extname(path))

    case Regex.run(~r/(.+)\s-\s(S\d+E\d+)/, basename) do
      [_, series, episode] -> "#{series} - #{episode}"
      _ -> basename <> Path.extname(path)
    end
  end

  @spec filename(any()) :: String.t()
  def filename(_), do: "N/A"

  @spec progress_field(:none, any(), any()) :: any()
  def progress_field(:none, _field, default), do: default

  @spec progress_field(map(), any(), any()) :: any()
  def progress_field(progress, field, default) when is_map(progress),
    do: Map.get(progress, field, default)

  @spec progress_field(any(), any(), any()) :: any()
  def progress_field(_, _field, default), do: default

  @spec value(nil) :: String.t()
  def value(nil), do: "N/A"

  @spec value(any()) :: String.t()
  def value(value), do: to_string(value)
end
