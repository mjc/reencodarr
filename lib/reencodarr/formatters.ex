defmodule Reencodarr.Formatters do
  @moduledoc """
  Minimal, idiomatic formatting utilities for Reencodarr.
  """

  alias Reencodarr.Core.{Parsers, Time}

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

  # === SIZE CONVERSION ===

  @doc """
  Converts a size value with unit to bytes.

  ## Examples

      iex> Formatters.size_to_bytes("1.5", "GB")
      1610612736

      iex> Formatters.size_to_bytes(100, "MB")
      104857600

      iex> Formatters.size_to_bytes("invalid", "MB")
      nil
  """
  @spec size_to_bytes(String.t() | number(), String.t()) :: non_neg_integer() | nil
  def size_to_bytes(size_str, unit) when is_binary(size_str) and is_binary(unit) do
    with {:ok, size_value} <- Parsers.parse_float_exact(size_str),
         {:ok, multiplier} <- get_unit_multiplier(unit) do
      round(size_value * multiplier)
    else
      _ -> nil
    end
  end

  def size_to_bytes(size_value, unit) when is_number(size_value) and is_binary(unit) do
    case get_unit_multiplier(unit) do
      {:ok, multiplier} -> round(size_value * multiplier)
      _ -> nil
    end
  end

  def size_to_bytes(_, _), do: nil

  @doc """
  Gets the byte multiplier for a given unit.

  ## Examples

      iex> Formatters.get_unit_multiplier("GB")
      {:ok, 1073741824}

      iex> Formatters.get_unit_multiplier("invalid")
      {:error, :unknown_unit}
  """
  @spec get_unit_multiplier(String.t()) :: {:ok, pos_integer()} | {:error, :unknown_unit}
  def get_unit_multiplier(unit) do
    case String.downcase(unit) do
      "b" -> {:ok, 1}
      "kb" -> {:ok, 1024}
      "mb" -> {:ok, 1024 * 1024}
      "gb" -> {:ok, 1024 * 1024 * 1024}
      "tb" -> {:ok, 1024 * 1024 * 1024 * 1024}
      _ -> {:error, :unknown_unit}
    end
  end

  @spec savings_bytes(pos_integer()) :: String.t()
  def savings_bytes(bytes) when is_integer(bytes) and bytes > 0, do: file_size(bytes)

  @spec savings_bytes(any()) :: String.t()
  def savings_bytes(_), do: "N/A"

  @doc """
  Formats potential file size savings in GiB.

  ## Examples

      iex> Formatters.potential_savings_gib(1000000000, 500000000)
      0.47

      iex> Formatters.potential_savings_gib(nil, 500000000)
      "N/A"
  """
  @spec potential_savings_gib(number(), number()) :: float()
  def potential_savings_gib(original_size, predicted_filesize)
      when is_number(original_size) and is_number(predicted_filesize) do
    savings = original_size - predicted_filesize
    file_size_gib(savings)
  end

  @spec potential_savings_gib(any(), any()) :: String.t()
  def potential_savings_gib(_, _), do: "N/A"

  @doc """
  Calculates and formats savings percentage.

  ## Examples

      iex> Formatters.savings_percentage(1000, 750)
      25.0

      iex> Formatters.savings_percentage(nil, 750)
      "N/A"
  """
  @spec savings_percentage(number(), number()) :: float()
  def savings_percentage(original_size, predicted_filesize)
      when is_number(original_size) and is_number(predicted_filesize) and original_size > 0 do
    Float.round((original_size - predicted_filesize) / original_size * 100, 1)
  end

  @spec savings_percentage(any(), any()) :: String.t()
  def savings_percentage(_, _), do: "N/A"

  @doc """
  Formats count values with K/M suffixes for display.

  ## Examples

      iex> Formatters.display_count(1500)
      "1.5K"

      iex> Formatters.display_count(2500000)
      "2.5M"

      iex> Formatters.display_count(500)
      "500"
  """
  @spec display_count(integer()) :: String.t()
  def display_count(count) when is_integer(count) do
    cond do
      count >= 1_000_000 -> "#{Float.round(count / 1_000_000, 1)}M"
      count >= 1_000 -> "#{Float.round(count / 1_000, 1)}K"
      true -> to_string(count)
    end
  end

  @spec display_count(any()) :: String.t()
  def display_count(_), do: "N/A"

  @doc """
  Formats a rate value to 1 decimal place.

  ## Examples

      iex> Formatters.rate(5.678)
      "5.7"

      iex> Formatters.rate(nil)
      "N/A"
  """
  @spec rate(number()) :: String.t()
  def rate(rate_value) when is_number(rate_value) do
    (rate_value * 1.0) |> Float.round(1) |> to_string()
  end

  @spec rate(any()) :: String.t()
  def rate(_), do: "N/A"

  @doc """
  Formats duration in seconds to minutes with 1 decimal place.

  ## Examples

      iex> Formatters.duration_minutes(150)
      "2.5 min"

      iex> Formatters.duration_minutes(nil)
      "Unknown"
  """
  @spec duration_minutes(number()) :: String.t()
  def duration_minutes(seconds) when is_number(seconds) do
    "#{Float.round(seconds / 60, 1)} min"
  end

  @spec duration_minutes(any()) :: String.t()
  def duration_minutes(_), do: "Unknown"

  @doc """
  Formats bytes to GB with specified decimal places.

  ## Examples

      iex> Formatters.size_gb(1073741824, 1)
      "1.0 GB"

      iex> Formatters.size_gb(nil, 1)
      "Unknown"
  """
  @spec size_gb(number(), integer()) :: String.t()
  def size_gb(bytes, decimal_places \\ 1)

  def size_gb(bytes, decimal_places) when is_number(bytes) do
    gb = bytes / (1024 * 1024 * 1024)
    "#{Float.round(gb, decimal_places)} GB"
  end

  def size_gb(_, _), do: "Unknown"

  @doc """
  Calculates and formats a percentage.

  ## Examples

      iex> Formatters.percentage(3, 4)
      75.0

      iex> Formatters.percentage(0, 0)
      0.0
  """
  @spec percentage(number(), number()) :: float()
  def percentage(numerator, denominator) when is_number(numerator) and is_number(denominator) do
    if denominator > 0 do
      (numerator / denominator * 100) |> Float.round(1)
    else
      0.0
    end
  end

  @spec percentage(any(), any()) :: float()
  def percentage(_, _), do: 0.0

  @doc """
  Formats resolution as "widthxheight".

  ## Examples

      iex> Formatters.resolution(1920, 1080)
      "1920x1080"

      iex> Formatters.resolution(nil, 1080)
      "Unknown"
  """
  @spec resolution(integer(), integer()) :: String.t()
  def resolution(width, height) when is_integer(width) and is_integer(height) do
    "#{width}x#{height}"
  end

  @spec resolution(any(), any()) :: String.t()
  def resolution(_, _), do: "Unknown"

  @doc """
  Formats a list of codecs for display.

  ## Examples

      iex> Formatters.codec_list(["h264", "aac", "mov"])
      "h264, aac"

      iex> Formatters.codec_list([])
      "None"

      iex> Formatters.codec_list(nil)
      "Unknown"
  """
  @spec codec_list(list() | nil) :: String.t()
  def codec_list(nil), do: "Unknown"
  def codec_list([]), do: "None"

  def codec_list(codecs) when is_list(codecs) do
    codecs |> Enum.take(2) |> Enum.join(", ")
  end

  def codec_list(_), do: "Unknown"

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
  def vmaf_score(score) when is_number(score), do: vmaf_score(score, 1)

  @spec vmaf_score(any()) :: String.t()
  def vmaf_score(score), do: to_string(score)

  @doc """
  Formats VMAF score with specified decimal places.

  ## Examples

      iex> Formatters.vmaf_score(95.67, 2)
      "95.67"

      iex> Formatters.vmaf_score(95.67, 1)
      "95.7"
  """
  @spec vmaf_score(number(), integer()) :: String.t()
  def vmaf_score(score, decimal_places) when is_number(score) and is_integer(decimal_places) do
    (score * 1.0) |> Float.round(decimal_places) |> to_string()
  end

  @spec vmaf_score(any(), integer()) :: String.t()
  def vmaf_score(score, _), do: to_string(score)

  @spec codec_info([String.t()], [String.t()]) :: String.t()
  def codec_info(video_codecs, audio_codecs)
      when is_list(video_codecs) and is_list(audio_codecs) do
    video = List.first(video_codecs) || "Unknown"
    audio = List.first(audio_codecs) || "Unknown"
    "#{video}/#{audio}"
  end

  @spec codec_info(any(), any()) :: String.t()
  def codec_info(_, _), do: "Unknown"

  # === TIME FORMATTING (delegated to Core.Time) ===

  defdelegate duration(seconds), to: Time, as: :format_duration
  defdelegate eta(eta), to: Time, as: :format_eta
  defdelegate relative_time(datetime), to: Time

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
