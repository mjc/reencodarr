defmodule Reencodarr.Media.AudioTrackInfo do
  @moduledoc false

  @spec primary_from_mediainfo(map()) :: map() | :error
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
  Returns all audio tracks with their ffmpeg audio stream index (0-based).
  The index corresponds to the -c:a:N stream selector in ffmpeg.
  """
  @spec all_from_mediainfo(map()) :: list({non_neg_integer(), map()})
  def all_from_mediainfo(%{"media" => %{"track" => tracks}}) when is_list(tracks) do
    tracks
    |> Enum.filter(fn track -> Map.get(track, "@type") == "Audio" end)
    |> Enum.with_index()
    |> Enum.map(fn {track, idx} -> {idx, build_track_info(track)} end)
  end

  def all_from_mediainfo(_mediainfo), do: []

  defp build_track_info(track) do
    %{
      codec: Map.get(track, "Format", ""),
      codec_id: Map.get(track, "CodecID", ""),
      channels: parse_channel_count(track),
      channel_layout: Map.get(track, "ChannelLayout", ""),
      bitrate: parse_bitrate(track),
      format_commercial_if_any: Map.get(track, "Format_Commercial_IfAny", ""),
      format_additionalfeatures: Map.get(track, "Format_AdditionalFeatures", "")
    }
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
