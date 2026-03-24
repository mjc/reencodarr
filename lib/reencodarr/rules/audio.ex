defmodule Reencodarr.Rules.Audio do
  @moduledoc """
  Audio encoding rules for ab-av1.

  Determines the audio codec strategy for encode context:
  - Copy if Atmos (preserve spatial metadata via explicit atmos flag or track markers)
  - Copy if already Opus (no re-encoding needed)
  - Transcode to Opus for multi-channel non-Atmos audio with channel-scaled bitrate
  - Normalize non-standard layouts (5.1(side) → 5.1) for receiver compatibility
  """

  alias Reencodarr.Media
  alias Reencodarr.Media.AudioTrackInfo

  @copy_audio [{"--acodec", "copy"}]

  @spec rules(Media.Video.t() | map()) :: list()
  def rules(%Media.Video{atmos: true}), do: @copy_audio

  def rules(%Media.Video{audio_codecs: audio_codecs} = video) when is_list(audio_codecs) do
    if already_opus?(audio_codecs) do
      @copy_audio
    else
      build_from_mediainfo(video)
    end
  end

  def rules(%Media.Video{}), do: @copy_audio

  # Handle map inputs (for tests that don't use proper structs)
  def rules(%{} = _video_map), do: @copy_audio

  defp build_from_mediainfo(%Media.Video{
         mediainfo: mediainfo,
         max_audio_channels: channels
       })
       when is_map(mediainfo) and is_integer(channels) and channels > 0 do
    case AudioTrackInfo.primary_from_mediainfo(mediainfo) do
      %{channels: track_channels, channel_layout: channel_layout} = track
      when is_integer(track_channels) and track_channels > 0 ->
        cond do
          track_channels <= 2 -> @copy_audio
          track_possibly_atmos?(track) -> @copy_audio
          true -> opus_rules(track_channels, channel_layout)
        end

      _ ->
        @copy_audio
    end
  end

  defp build_from_mediainfo(_video), do: @copy_audio

  defp opus_rules(channels, channel_layout) do
    base = [
      {"--acodec", "libopus"},
      {"--enc", "b:a=#{opus_bitrate(channels)}k"}
    ]

    if needs_layout_normalization?(channel_layout) do
      base ++ [{"--enc", "af=aformat=channel_layouts=5.1|7.1|stereo"}]
    else
      base
    end
  end

  defp already_opus?(audio_codecs) do
    Enum.any?(audio_codecs, fn codec ->
      codec |> normalize_codec_string() |> String.contains?("opus")
    end)
  end

  defp track_possibly_atmos?(track) do
    commercial = track.format_commercial_if_any |> normalize_codec_string()
    additional = track.format_additionalfeatures |> normalize_codec_string()

    String.contains?(commercial, "atmos") or
      String.contains?(additional, "joc") or
      String.contains?(additional, "atmos")
  end

  defp normalize_codec_string(nil), do: ""

  defp normalize_codec_string(value),
    do: value |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "")

  defp needs_layout_normalization?(nil), do: true
  defp needs_layout_normalization?(""), do: true

  defp needs_layout_normalization?(channel_layout) do
    normalized = String.downcase(channel_layout)

    String.contains?(normalized, "side") or
      String.contains?(normalized, "wide") or
      String.contains?(normalized, "hexagonal") or
      String.contains?(normalized, "ls rs") or
      String.contains?(normalized, "sl sr")
  end

  defp opus_bitrate(channels) when channels <= 2, do: 96
  defp opus_bitrate(3), do: 160
  defp opus_bitrate(4), do: 192
  defp opus_bitrate(5), do: 224
  defp opus_bitrate(6), do: 256
  defp opus_bitrate(7), do: 320
  defp opus_bitrate(8), do: 450
  defp opus_bitrate(channels), do: min(510, channels * 64)
end
