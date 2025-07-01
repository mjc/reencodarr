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
    |> Enum.map(&get_channel_count_from_track/1)
    |> Enum.max(fn -> 0 end)
  end

  # Helper function to better extract channel count from audio track
  # This tries to use ChannelPositions or ChannelLayout when available
  # to distinguish between 5.0 and 5.1 surround sound
  @spec get_channel_count_from_track(map()) :: integer()
  defp get_channel_count_from_track(track) do
    # Try multiple MediaInfo field name variations (case-insensitive)
    channel_positions = get_field_case_insensitive(track, ["ChannelPositions", "Channel_s_", "ChannelLayout"])
    channel_layout = get_field_case_insensitive(track, ["ChannelLayout", "Channel_Layout", "Channels_Layout"])
    channels_string = get_field_case_insensitive(track, ["Channel(s)/String", "Channels/String", "ChannelString"])

    # Check if this is 5.1 surround by looking for LFE in channel positions
    cond do
      # Look for LFE (Low Frequency Effects) channel in various fields (case-insensitive)
      contains_lfe_or_surround?(channel_positions) or
      contains_lfe_or_surround?(channel_layout) or
      contains_lfe_or_surround?(channels_string) ->
        detect_surround_channel_count(channel_positions, channel_layout, channels_string)

      # Fall back to the raw channel count
      true ->
        parse_int(Map.get(track, "Channels", "0"), 0)
    end
  end

  # Helper to get field with case-insensitive matching
  defp get_field_case_insensitive(track, field_names) do
    Enum.find_value(field_names, "", fn field_name ->
      Map.get(track, field_name) ||
      Enum.find_value(track, fn {k, v} ->
        if String.downcase(to_string(k)) == String.downcase(field_name), do: v
      end)
    end) || ""
  end

  # Check if string contains LFE or surround sound indicators (case-insensitive)
  defp contains_lfe_or_surround?(str) when is_binary(str) do
    lower_str = String.downcase(str)
    String.contains?(lower_str, "lfe") or
    String.contains?(lower_str, "5.1") or
    String.contains?(lower_str, "7.1") or
    String.contains?(lower_str, "6.1") or
    String.contains?(lower_str, "surround")
  end
  defp contains_lfe_or_surround?(_), do: false

  # Detect channel count from surround sound indicators
  defp detect_surround_channel_count(channel_positions, channel_layout, channels_string) do
    combined = "#{channel_positions} #{channel_layout} #{channels_string}" |> String.downcase()

    cond do
      String.contains?(combined, "9.1") -> 10
      String.contains?(combined, "9.2") -> 11
      String.contains?(combined, "8.1") -> 9
      String.contains?(combined, "8.2") -> 10
      String.contains?(combined, "7.1") -> 8
      String.contains?(combined, "7.2") -> 9
      String.contains?(combined, "6.1") -> 7
      String.contains?(combined, "5.1") -> 6
      String.contains?(combined, "4.1") -> 5
      String.contains?(combined, "3.1") -> 4
      String.contains?(combined, "2.1") -> 3
      # Default fallback for any LFE detection
      String.contains?(combined, "lfe") -> 6  # Assume 5.1 if LFE detected but format unclear
      true -> 6  # Conservative assumption for surround sound
    end
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
