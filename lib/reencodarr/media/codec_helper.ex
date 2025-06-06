defmodule Reencodarr.Media.CodecHelper do
  @spec get_int(map(), String.t(), String.t()) :: integer()
  def get_int(mediainfo, track_type, key) do
    mediainfo
    |> get_track(track_type)
    |> Map.get(key, "0")
    |> to_string()
    |> String.to_integer()
  end

  @spec get_str(map(), String.t(), String.t()) :: String.t()
  def get_str(mediainfo, track_type, key) do
    mediainfo
    |> get_track(track_type)
    |> Map.get(key, "")
    |> to_string()
  end

  @spec get_track(map(), String.t()) :: map() | nil
  def get_track(mediainfo, type) do
    Enum.find(mediainfo["media"]["track"], &(&1["@type"] == type))
  end

  def get_tracks(mediainfo, type) do
    (mediainfo["media"]["track"] || [])
    |> Enum.filter(&(&1["@type"] == type))
  end

  @spec parse_duration(String.t() | number()) :: number()
  def parse_duration(duration) when is_binary(duration) do
    case String.split(duration, ":") do
      [hours, minutes, seconds] ->
        String.to_integer(hours) * 3600 + String.to_integer(minutes) * 60 +
          String.to_integer(seconds)

      [minutes, seconds] ->
        String.to_integer(minutes) * 60 + String.to_integer(seconds)

      [seconds] ->
        String.to_integer(seconds)

      _ ->
        0
    end
  end

  def parse_duration(duration) when is_number(duration), do: duration
  def parse_duration(_), do: 0

  def parse_int(val, default \\ 0)
  def parse_int(val, _default) when is_integer(val), do: val

  def parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {i, _} -> i
      :error -> default
    end
  end

  def parse_int(_, default), do: default

  def parse_float(val, default \\ 0.0)
  def parse_float(val, _default) when is_float(val), do: val

  def parse_float(val, default) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> default
    end
  end

  def parse_float(_, default), do: default

  def parse_resolution(res) do
    [w, h] = (res || "0x0") |> String.split("x") |> Enum.map(&parse_int(&1, 0))
    {w, h}
  end

  def get_first(list, default \\ nil) do
    Enum.find(list, & &1) || default
  end

  def parse_hdr(formats) do
    formats
    |> Enum.reduce([], fn format, acc ->
      if format &&
           (String.contains?(format, "Dolby Vision") || String.contains?(format, "HDR") ||
              String.contains?(format, "PQ") || String.contains?(format, "SMPTE")) do
        [format | acc]
      else
        acc
      end
    end)
    |> Enum.uniq()
    |> Enum.join(", ")
  end

  @spec parse_hdr_from_video(nil | map()) :: String.t() | nil
  def parse_hdr_from_video(nil), do: nil

  def parse_hdr_from_video(%{} = video) do
    parse_hdr([
      video["HDR_Format"],
      video["HDR_Format_Compatibility"],
      video["transfer_characteristics"]
    ])
  end

  @spec has_atmos?(list()) :: boolean
  def has_atmos?(audio_tracks) when is_list(audio_tracks) do
    Enum.any?(audio_tracks, fn t ->
      String.contains?(Map.get(t, "Format_AdditionalFeatures", ""), "JOC") or
        String.contains?(Map.get(t, "Format_Commercial_IfAny", ""), "Atmos")
    end)
  end

  @spec max_audio_channels(list()) :: integer()
  def max_audio_channels(audio_tracks) when is_list(audio_tracks) do
    audio_tracks
    |> Enum.map(&parse_int(Map.get(&1, "Channels", "0"), 0))
    |> Enum.max(fn -> 0 end)
  end

  @spec parse_subtitles(String.t() | list() | nil) :: list()
  def parse_subtitles(subtitles) do
    cond do
      is_binary(subtitles) -> String.split(subtitles, "/")
      is_list(subtitles) -> subtitles
      true -> []
    end
  end
end
