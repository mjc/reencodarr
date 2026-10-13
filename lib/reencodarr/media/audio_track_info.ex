defmodule Reencodarr.Media.AudioTrackInfo do
  @moduledoc false

  @type audio_track :: %{
          codec: String.t(),
          codec_id: String.t(),
          channels: non_neg_integer(),
          channel_layout: String.t(),
          bitrate: non_neg_integer() | nil,
          format_commercial_if_any: String.t(),
          format_additionalfeatures: String.t(),
          language: String.t(),
          probe: map(),
          extra: map()
        }

  @spec primary_from_mediainfo(map()) :: audio_track() | :error
  def primary_from_mediainfo(%{"media" => %{"track" => tracks}}) when is_list(tracks) do
    audio_tracks =
      Enum.filter(tracks, fn track ->
        Map.get(track, "@type") == "Audio"
      end)

    case Enum.find(audio_tracks, List.first(audio_tracks), &default_audio_track?/1) do
      %{} = track ->
        build_track_info(track)

      _other ->
        :error
    end
  end

  def primary_from_mediainfo(_mediainfo), do: :error

  @doc """
  Returns all audio tracks with their source audio stream index (0-based).
  Output audio indexes may differ when tracks are excluded from the encode.
  """
  @spec all_from_mediainfo(map()) :: list({non_neg_integer(), audio_track()})
  def all_from_mediainfo(%{"media" => %{"track" => tracks}}) when is_list(tracks) do
    tracks
    |> Enum.filter(fn track -> Map.get(track, "@type") == "Audio" end)
    |> Enum.with_index()
    |> Enum.map(fn {track, idx} -> {idx, build_track_info(track)} end)
  end

  def all_from_mediainfo(_mediainfo), do: []

  @spec build_track_info(map()) :: audio_track()
  defp build_track_info(track) do
    resolved = resolved_identity(track)

    %{
      codec: text_field(resolved, "Format"),
      codec_id: text_field(resolved, "CodecID"),
      channels: parse_channel_count(track),
      channel_layout: text_field(resolved, "ChannelLayout"),
      bitrate: parse_bitrate(track),
      format_commercial_if_any: text_field(track, "Format_Commercial_IfAny"),
      format_additionalfeatures: text_field(track, "Format_AdditionalFeatures"),
      language: text_field(track, "Language"),
      probe: map_field(track, "ReencodarrAudioProbe"),
      extra: map_field(track, "extra")
    }
  end

  @spec ambiguous_identity?(map()) :: boolean()
  def ambiguous_identity?(track) do
    identities = Enum.map(["Format", "CodecID"], &(track |> text_field(&1) |> String.downcase()))
    identities == ["", ""] or Enum.any?(identities, &(&1 in ["a_quicktime", "unknown", "enca"]))
  end

  @spec encrypted?(audio_track() | map()) :: boolean()
  def encrypted?(track) do
    probe = Map.get(track, :probe, map_field(track, "ReencodarrAudioProbe"))

    [
      Map.get(track, :codec, text_field(track, "Format")),
      Map.get(track, :codec_id, text_field(track, "CodecID")),
      probe["codec_tag_string"]
    ]
    |> Enum.any?(fn
      value when is_binary(value) -> String.downcase(String.trim(value)) == "enca"
      _ -> false
    end)
  end

  @probe_codecs %{
    "ac3" => "AC-3",
    "aac" => "AAC",
    "flac" => "FLAC",
    "alac" => "ALAC",
    "opus" => "Opus",
    "mp3" => "MP3",
    "mp2" => "MP2",
    "vorbis" => "Vorbis"
  }

  defp resolved_identity(track) do
    probe = map_field(track, "ReencodarrAudioProbe")
    format = Map.get(@probe_codecs, probe["codec_name"])

    if ambiguous_identity?(track) and is_binary(format) and not encrypted?(track) and
         is_nil(probe["error"]) and consistent_probe?(track, probe, format) do
      track
      |> Map.put("Format", format)
      |> Map.put("CodecID", format)
      |> Map.put("ChannelLayout", probe["channel_layout"] || track["ChannelLayout"])
    else
      track
    end
  end

  defp consistent_probe?(track, probe, format) do
    normalize = fn value -> String.downcase(value) |> String.replace(~r/[^a-z0-9]/, "") end
    format = normalize.(format)
    identities = Enum.map(["Format", "CodecID"], &(track |> text_field(&1) |> normalize.()))

    Enum.all?(identities, &(&1 in ["", "aquicktime", "unknown", format, "a" <> format])) and
      probe["channels"] == parse_channel_count(track)
  end

  defp text_field(track, key) do
    case Map.get(track, key) do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp map_field(track, key) do
    case Map.get(track, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp default_audio_track?(%{"Default" => "Yes"}), do: true
  defp default_audio_track?(%{"Default" => true}), do: true
  defp default_audio_track?(_track), do: false

  defp parse_channel_count(%{"Channels" => channels}) when is_integer(channels), do: channels

  defp parse_channel_count(%{"Channels" => channels}) when is_binary(channels) do
    case Integer.parse(channels) do
      {value, _rest} -> value
      :error -> 0
    end
  end

  defp parse_channel_count(_track), do: 0

  defp parse_bitrate(%{"BitRate" => bitrate}) when is_integer(bitrate), do: bitrate

  defp parse_bitrate(%{"BitRate" => bitrate}) when is_binary(bitrate) do
    case Integer.parse(bitrate) do
      {value, _rest} -> value
      :error -> nil
    end
  end

  defp parse_bitrate(_track), do: nil
end
