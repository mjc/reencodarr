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
        %{
          codec: Map.get(track, "Format", ""),
          channels: parse_channel_count(track),
          channel_layout: Map.get(track, "ChannelLayout", ""),
          format_commercial_if_any: Map.get(track, "Format_Commercial_IfAny", ""),
          format_additionalfeatures: Map.get(track, "Format_AdditionalFeatures", "")
        }

      _other ->
        :error
    end
  end

  def primary_from_mediainfo(_mediainfo), do: :error

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
end
