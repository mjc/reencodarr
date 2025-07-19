defmodule Reencodarr.Media.CodecHelper do
  @moduledoc "Provides helper functions for codec-related operations."

  @spec get_int(map(), String.t(), String.t()) :: integer()
  def get_int(mediainfo, track_type, key) do
    case get_track(mediainfo, track_type) do
      nil -> 0
      track ->
        track
        |> Map.get(key, "0")
        |> to_string()
        |> String.to_integer()
    end
  end

  @spec get_str(map(), String.t(), String.t()) :: String.t()
  def get_str(mediainfo, track_type, key) do
    case get_track(mediainfo, track_type) do
      nil -> ""
      track ->
        track
        |> Map.get(key, "")
        |> to_string()
    end
  end

  @spec get_track(map() | nil, String.t()) :: map() | nil
  def get_track(nil, _type), do: nil
  def get_track(%{"media" => nil}, _type), do: nil
  def get_track(%{"media" => %{"track" => nil}}, _type), do: nil
  def get_track(%{"media" => %{"track" => []}}, _type), do: nil

  def get_track(%{"media" => %{"track" => tracks}}, type) when is_list(tracks) do
    Enum.find(tracks, &(&1["@type"] == type))
  end

  def get_track(%{"media" => %{"track" => track}}, type) when is_map(track) do
    if track["@type"] == type, do: track, else: nil
  end

  def get_track(_mediainfo, _type), do: nil

  def get_tracks(nil, _type), do: []
  def get_tracks(%{"media" => nil}, _type), do: []
  def get_tracks(%{"media" => %{"track" => nil}}, _type), do: []
  def get_tracks(%{"media" => %{"track" => []}}, _type), do: []

  def get_tracks(%{"media" => %{"track" => tracks}}, type) when is_list(tracks) do
    Enum.filter(tracks, &(&1["@type"] == type))
  end

  def get_tracks(%{"media" => %{"track" => track}}, type) when is_map(track) do
    if track["@type"] == type, do: [track], else: []
  end

  def get_tracks(_mediainfo, _type), do: []

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
    channel_positions =
      get_field_case_insensitive(track, ["ChannelPositions", "Channel_s_", "ChannelLayout"])

    channel_layout =
      get_field_case_insensitive(track, ["ChannelLayout", "Channel_Layout", "Channels_Layout"])

    channels_string =
      get_field_case_insensitive(track, ["Channel(s)/String", "Channels/String", "ChannelString"])

    # Check if this is 5.1 surround by looking for LFE in channel positions
    # Determine surround vs default channel count
    case contains_lfe_or_surround?(channel_positions) or
           contains_lfe_or_surround?(channel_layout) or
           contains_lfe_or_surround?(channels_string) do
      true ->
        detect_surround_channel_count(channel_positions, channel_layout, channels_string)

      false ->
        parse_int(Map.get(track, "Channels", "0"), 0)
    end
  end

  # Finds a key in map ignoring case
  defp get_field_case_insensitive(track, field_names) do
    Enum.find_value(field_names, "", &get_field_value(track, &1))
  end

  # Attempt direct map lookup or case-insensitive key match
  defp get_field_value(track, field_name) do
    Map.get(track, field_name) ||
      case Enum.find(track, fn {k, _v} ->
             String.downcase(to_string(k)) == String.downcase(field_name)
           end) do
        {_, v} -> v
        _ -> nil
      end
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
    # Patterns to counts in priority order
    patterns = [
      {"9.1", 10},
      {"9.2", 11},
      {"8.1", 9},
      {"8.2", 10},
      {"7.1", 8},
      {"7.2", 9},
      {"6.1", 7},
      {"5.1", 6},
      {"4.1", 5},
      {"3.1", 4},
      {"2.1", 3},
      {"lfe", 6}
    ]

    Enum.find_value(patterns, fn {substr, count} ->
      if String.contains?(combined, substr), do: count, else: nil
    end) || 6
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
