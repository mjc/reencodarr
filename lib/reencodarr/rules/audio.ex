defmodule Reencodarr.Rules.Audio do
  @moduledoc """
  Audio encoding rules for ab-av1 with codec-aware bitrate scaling.

  Determines the audio codec strategy:
  - Copy if Atmos (preserve spatial metadata)
  - Copy if already Opus (no re-encoding needed)
  - Copy if source codec/channel combo is invalid
  - Copy if lossy source bitrate is unknown
  - Transcode to Opus for lossy audio, scaling bitrate by codec efficiency
  - Normalize non-standard layouts (5.1(side) → 5.1) for receiver compatibility
  """

  alias Reencodarr.Media
  alias Reencodarr.Media.AudioTrackInfo

  @copy_audio [{"--acodec", "copy"}]

  # Opus transparent bitrate targets by channel count
  @opus_targets %{
    # mono
    1 => 64,
    # stereo
    2 => 128,
    # 5.1
    6 => 256,
    # 7.1
    8 => 384
  }

  # Codec efficiency reduction factors: lower = more efficient (Opus can use less bitrate)
  @codec_factors %{
    "mp3" => 0.50,
    "mp2" => 0.55,
    "aac" => 0.80,
    "vorbis" => 0.80,
    "ac3" => 0.70,
    "eac3" => 0.75,
    "dts" => 0.45,
    "opus" => 1.00
  }

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
  def rules(%{} = _video_map), do: @copy_audio

  defp build_from_mediainfo(%Media.Video{
         mediainfo: mediainfo,
         max_audio_channels: channels
       })
       when is_map(mediainfo) and is_integer(channels) and channels > 0 do
    case AudioTrackInfo.primary_from_mediainfo(mediainfo) do
      %{channels: track_channels, channel_layout: channel_layout} = track
      when is_integer(track_channels) and track_channels > 0 ->
        if track_possibly_atmos?(track) do
          @copy_audio
        else
          calculate_audio_rules(track, track_channels, channel_layout)
        end

      _ ->
        @copy_audio
    end
  end

  defp build_from_mediainfo(_video), do: @copy_audio

  # Determine encoding rules based on codec, channels, and bitrate
  defp calculate_audio_rules(track, channels, channel_layout) do
    codec = track.codec |> normalize_codec_string()
    bitrate = track.bitrate
    is_lossless = lossless_codec?(codec)

    cond do
      # Codec/channel combo is invalid (e.g., MP3 5.1)
      invalid_codec_channel_combo?(codec, channels) ->
        @copy_audio

      # Lossless source: use transparent target for channel count
      is_lossless ->
        target_bitrate = Map.get(@opus_targets, channels, 256)
        opus_rules(target_bitrate, channel_layout)

      # Lossy source with known bitrate: scale by codec efficiency
      bitrate && is_integer(bitrate) && bitrate > 0 ->
        factor = Map.get(@codec_factors, codec, 0.75)
        calculated = round(bitrate / 1000 * factor)
        max_bitrate = Map.get(@opus_targets, channels, 256)
        target = min(calculated, max_bitrate)
        opus_rules(target, channel_layout)

      # Lossy source with unknown bitrate: copy (don't guess)
      true ->
        @copy_audio
    end
  end

  defp opus_rules(target_bitrate, channel_layout) do
    base = [
      {"--acodec", "libopus"},
      {"--enc", "b:a=#{target_bitrate}k"}
    ]

    if needs_layout_normalization?(channel_layout) do
      base ++ [{"--enc", "af=aformat=channel_layouts=5.1|7.1|stereo"}]
    else
      base
    end
  end

  # Check if codec/channel combination is invalid/unlikely
  defp invalid_codec_channel_combo?(codec, channels) when channels > 2 do
    # MP3 and MP2 only support up to stereo
    String.contains?(codec, "mp3") or String.contains?(codec, "mp2")
  end

  defp invalid_codec_channel_combo?(_codec, _channels), do: false

  defp lossless_codec?(codec) do
    Enum.any?(["flac", "alac", "truehd", "mlp", "dtshd", "pcm"], &String.contains?(codec, &1))
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
end
