defmodule Reencodarr.Rules.Audio do
  @moduledoc """
  Audio encoding rules for ab-av1 with codec-aware bitrate scaling.

  Determines the audio codec strategy:
  - Copy if already Opus (no re-encoding needed)
  - Copy all if mediainfo unavailable
  - Transcode all to Opus if no Atmos tracks present
  - Per-stream encoding if Atmos tracks are present: copy Atmos, transcode others
    (ab-av1 uses -map 0 so --acodec applies to all; use --enc c:a:N= to override per-track)
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
  def rules(%Media.Video{audio_codecs: audio_codecs} = video) when is_list(audio_codecs) do
    if already_opus?(audio_codecs) do
      @copy_audio
    else
      build_from_mediainfo(video)
    end
  end

  def rules(%Media.Video{}), do: @copy_audio
  def rules(%{} = _video_map), do: @copy_audio

  defp build_from_mediainfo(%Media.Video{mediainfo: mediainfo, max_audio_channels: channels})
       when is_map(mediainfo) and is_integer(channels) and channels > 0 do
    indexed_tracks = AudioTrackInfo.all_from_mediainfo(mediainfo)

    {atmos, non_atmos} =
      Enum.split_with(indexed_tracks, fn {_idx, t} -> track_possibly_atmos?(t) end)

    route_by_atmos(atmos, non_atmos, mediainfo)
  end

  defp build_from_mediainfo(_video), do: @copy_audio

  defp route_by_atmos([], _non_atmos, mediainfo), do: encode_uniform(mediainfo)
  defp route_by_atmos(_atmos, [], _mediainfo), do: @copy_audio
  # Mixed Atmos + non-Atmos: apply per-stream rules to each non-Atmos track
  defp route_by_atmos(_atmos, non_atmos, _mediainfo), do: encode_mixed(non_atmos)

  # No Atmos tracks: apply rules uniformly across all tracks
  # Build per-stream overrides for each track, or copy if issues found
  defp encode_uniform(mediainfo) do
    indexed_tracks = AudioTrackInfo.all_from_mediainfo(mediainfo)

    overrides =
      Enum.flat_map(indexed_tracks, fn {idx, track} ->
        build_per_stream_overrides(idx, track)
      end)

    case overrides do
      [] -> @copy_audio
      _ -> @copy_audio ++ overrides
    end
  end

  # Mixed Atmos + non-Atmos: base is --acodec copy, override non-Atmos tracks per-stream
  defp encode_mixed(non_atmos_tracks) do
    overrides =
      Enum.flat_map(non_atmos_tracks, fn {idx, track} ->
        build_per_stream_overrides(idx, track)
      end)

    case overrides do
      [] -> @copy_audio
      _ -> @copy_audio ++ overrides
    end
  end

  defp build_per_stream_overrides(idx, track) do
    channels = track.channels

    with true <- is_integer(channels) and channels > 0,
         target_bitrate when not is_nil(target_bitrate) <- opus_target_for_track(track, channels) do
      opus_stream_args(idx, target_bitrate, track.channel_layout)
    else
      _ -> []
    end
  end

  defp opus_stream_args(idx, target_bitrate, channel_layout) do
    base = [
      {"--enc", "c:a:#{idx}=libopus"},
      {"--enc", "b:a:#{idx}=#{target_bitrate}k"}
    ]

    if needs_layout_normalization?(channel_layout) do
      base ++ [{"--enc", "filter:a:#{idx}=aformat=channel_layouts=5.1|7.1|stereo"}]
    else
      base
    end
  end

  defp opus_target_for_track(track, channels) do
    codec = track.codec |> normalize_codec_string()
    bitrate = track.bitrate

    cond do
      invalid_codec_channel_combo?(codec, channels) ->
        nil

      lossless_codec?(codec) ->
        Map.get(@opus_targets, channels, 256)

      bitrate && is_integer(bitrate) && bitrate > 0 ->
        factor = Map.get(@codec_factors, codec, 0.75)
        calculated = round(bitrate / 1000 * factor)
        max_bitrate = Map.get(@opus_targets, channels, 256)
        min(calculated, max_bitrate)

      true ->
        nil
    end
  end

  defp invalid_codec_channel_combo?(codec, channels) when channels > 2 do
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
