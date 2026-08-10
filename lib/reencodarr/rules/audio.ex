defmodule Reencodarr.Rules.Audio do
  @moduledoc """
  Audio encoding rules for ab-av1 with codec-aware bitrate scaling.

  Determines the audio codec strategy:
  - Copy only if every track is already Opus (no re-encoding needed)
  - Copy all if mediainfo unavailable
  - Transcode all to Opus if no copy-through tracks are present
  - Per-stream encoding if Atmos, DTS:X, or Opus tracks are present: copy them, transcode others
    (ab-av1 uses -map 0 so --acodec applies to all; use --enc c:a:N= to override per-track)
  - Normalize non-standard layouts (5.1(side) → 5.1) for receiver compatibility
  """

  alias Reencodarr.Media
  alias Reencodarr.Media.AudioTrackInfo

  defmodule ClassificationError do
    @moduledoc false

    defexception [:track_index, :format, :codec_id, :reason]

    @type t :: %__MODULE__{
            track_index: non_neg_integer() | nil,
            format: String.t() | nil,
            codec_id: String.t() | nil,
            reason: String.t()
          }

    @impl Exception
    def message(%__MODULE__{} = error) do
      track = if is_integer(error.track_index), do: " audio track #{error.track_index}", else: ""

      identity =
        [error.format, error.codec_id]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(" / ")

      suffix = if identity == "", do: "", else: " (#{identity})"
      "cannot classify#{track}#{suffix}: #{error.reason}"
    end
  end

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

  @unsupported_codec_ids ~w(dtsx dtsy mha1 mha2 mhm1 mhm2 iamf apac a3ds)
  @unsupported_formats ~w(dtsuhd mpegh3daudio iamf applepositionalaudiocodec aurocx auromax iab mpegiimmersiveaudio)
  @unsupported_brands ~w(iamf eclipsa aurocx auromax applepositionalaudio)
  @ordinary_formats ~w(
    aac ac3 eac3 eac3atmos dts dtshdmasteraudio flac alac pcm mp3 mp2 mpegaudio
    vorbis wavpack ape truehd truehdatmos dolbytruehd mlp mlpfba ac4
  )
  @ordinary_codec_ids ~w(
    aaac aaac2 aac ac3 aac3 aeac3 eac3 ec3 adts adtslossless aflac flac
    atruehd truehd apcmintlit apcmfloat ampegl2 ampegl3 mp4a402 opus aopus
  )

  @spec rules(Media.Video.t() | map()) :: list()
  def rules(%Media.Video{mediainfo: mediainfo} = video) when is_map(mediainfo) do
    build_from_mediainfo(video)
  end

  def rules(%Media.Video{audio_codecs: audio_codecs} = video) when is_list(audio_codecs) do
    if audio_codecs != [] and all_opus?(audio_codecs) do
      @copy_audio
    else
      build_from_mediainfo(video)
    end
  end

  def rules(%Media.Video{}), do: @copy_audio
  def rules(%{} = _video_map), do: @copy_audio

  defp build_from_mediainfo(%Media.Video{mediainfo: mediainfo}) when is_map(mediainfo) do
    validate_container!(mediainfo)
    indexed_tracks = AudioTrackInfo.all_from_mediainfo(mediainfo)

    {copy_through, non_copy_through} =
      Enum.split_with(indexed_tracks, fn {idx, track} -> track_should_copy?(idx, track) end)

    route_by_copy_through(copy_through, non_copy_through, mediainfo)
  end

  defp build_from_mediainfo(_video), do: @copy_audio

  defp route_by_copy_through([], _non_copy_through, mediainfo), do: encode_uniform(mediainfo)
  defp route_by_copy_through(_copy_through, [], _mediainfo), do: @copy_audio

  defp route_by_copy_through(_copy_through, non_copy_through, _mediainfo),
    do: encode_mixed(non_copy_through)

  # No copy-through tracks: apply rules uniformly across all tracks
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

  # Mixed copy-through + transcode tracks: base is --acodec copy, override transcode tracks per-stream
  defp encode_mixed(non_copy_through_tracks) do
    overrides =
      Enum.flat_map(non_copy_through_tracks, fn {idx, track} ->
        build_per_stream_overrides(idx, track)
      end)

    case overrides do
      [] -> @copy_audio
      _ -> @copy_audio ++ overrides
    end
  end

  defp build_per_stream_overrides(idx, %{channels: channels} = track)
       when is_integer(channels) and channels > 0 do
    case opus_target_for_track(track, channels) do
      target_bitrate when is_integer(target_bitrate) ->
        opus_stream_args(idx, target_bitrate, track.channel_layout)

      nil ->
        raise_classification!(idx, track, "could not select an Opus bitrate")
    end
  end

  defp build_per_stream_overrides(idx, track),
    do: raise_classification!(idx, track, "missing or invalid channel count")

  defp opus_stream_args(idx, target_bitrate, channel_layout) do
    base = [
      {"--enc", "c:a:#{idx}=libopus"},
      {"--enc", "b:a:#{idx}=#{target_bitrate}k"}
    ]

    layout_args =
      if needs_layout_normalization?(channel_layout) do
        [{"--enc", "filter:a:#{idx}=aformat=channel_layouts=5.1|7.1|stereo"}]
      else
        []
      end

    base ++ layout_args
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
        Map.get(@opus_targets, channels, 256)
    end
  end

  defp invalid_codec_channel_combo?(codec, channels) when channels > 2 do
    String.contains?(codec, "mp3") or String.contains?(codec, "mp2")
  end

  defp invalid_codec_channel_combo?(_codec, _channels), do: false

  defp lossless_codec?(codec) do
    Enum.any?(["flac", "alac", "truehd", "mlp", "dtshd", "pcm"], &String.contains?(codec, &1))
  end

  defp all_opus?(audio_codecs) do
    Enum.all?(audio_codecs, fn codec ->
      codec |> normalize_codec_string() |> String.contains?("opus")
    end)
  end

  defp track_should_copy?(idx, track) do
    codec = track.codec |> normalize_codec_string()
    codec_id = track.codec_id |> normalize_codec_string()
    commercial = track.format_commercial_if_any |> normalize_codec_string()
    additional = track.format_additionalfeatures |> normalize_codec_string()
    profile = track.format_profile |> normalize_codec_string()

    case object_rejection_reason(codec, codec_id, commercial, additional, profile) do
      nil -> classify_supported_track(idx, track, codec, codec_id, commercial, additional)
      reason -> raise_classification!(idx, track, reason)
    end
  end

  defp object_rejection_reason(codec, codec_id, commercial, additional, profile) do
    cond do
      unsupported_identity?(codec, codec_id, commercial, additional, profile) ->
        "object/scene audio is unsupported by Matroska output"

      immersive_ac4?(codec, codec_id, commercial, additional, profile) ->
        "immersive AC-4 is unsupported by Matroska output"

      true ->
        nil
    end
  end

  defp classify_supported_track(idx, track, codec, codec_id, commercial, additional) do
    cond do
      copy_through?(codec, codec_id, commercial, additional) ->
        true

      codec == "" and codec_id == "" ->
        raise_classification!(idx, track, "missing format and codec identifier")

      not is_integer(track.channels) or track.channels <= 0 ->
        raise_classification!(idx, track, "missing or invalid channel count")

      invalid_codec_channel_combo?(codec, track.channels) ->
        raise_classification!(idx, track, "codec and channel count are inconsistent")

      ordinary_codec?(codec, codec_id) ->
        false

      true ->
        raise_classification!(idx, track, "unknown audio identity")
    end
  end

  defp copy_through?(codec, codec_id, commercial, additional) do
    opus?(codec, codec_id) or
      truehd_atmos?(codec, codec_id, commercial, additional) or
      eac3_atmos?(codec, codec_id, commercial, additional) or
      dtsx?(codec, codec_id, commercial, additional)
  end

  defp unsupported_identity?(codec, codec_id, commercial, additional, profile) do
    registered_object_identity?(codec, codec_id) or
      Enum.any?([commercial, additional], &contains_any?(&1, @unsupported_brands)) or
      contains_any?(profile, ["mpegiimmersiveaudio", "mpegh"])
  end

  defp registered_object_identity?(codec, codec_id) do
    codec_id in @unsupported_codec_ids or codec in @unsupported_formats or
      String.starts_with?(codec, "dtsuhd") or String.starts_with?(codec, "mpegh3daudio")
  end

  defp contains_any?(value, markers), do: Enum.any?(markers, &String.contains?(value, &1))

  defp immersive_ac4?(codec, codec_id, commercial, additional, profile) do
    ac4? = codec == "ac4" or codec_id == "ac4"

    ac4? and
      Enum.any?([commercial, additional, profile], fn value ->
        String.contains?(value, "atmos") or String.contains?(value, "immersive") or
          String.contains?(value, "ims") or String.contains?(value, "object")
      end)
  end

  defp opus?(codec, codec_id), do: codec == "opus" or codec_id in ["opus", "aopus"]

  defp truehd_atmos?(codec, codec_id, commercial, additional) do
    truehd? =
      codec in ["truehd", "truehdatmos", "dolbytruehd", "mlpfba"] or
        codec_id in ["truehd", "atruehd"]

    truehd? and atmos_marker?(commercial, additional)
  end

  defp eac3_atmos?(codec, codec_id, commercial, additional) do
    eac3? =
      codec in ["eac3", "eac3atmos", "dolbydigitalplus"] or
        codec_id in ["eac3", "aeac3", "ec3"]

    eac3? and (atmos_marker?(commercial, additional) or String.contains?(additional, "joc"))
  end

  defp dtsx?(codec, codec_id, commercial, additional) do
    dts? = codec in ["dts", "dtsx"] or codec_id in ["adts", "adtslossless"]

    dts? and
      (String.contains?(commercial, "dtsx") or String.contains?(additional, "dtsx") or
         String.contains?(additional, "xllx"))
  end

  defp atmos_marker?(commercial, additional) do
    String.contains?(commercial, "atmos") or String.contains?(additional, "atmos")
  end

  defp ordinary_codec?(codec, codec_id) do
    codec in @ordinary_formats or codec_id in @ordinary_codec_ids or
      String.starts_with?(codec_id, "aaac") or String.starts_with?(codec_id, "apcm")
  end

  defp validate_container!(mediainfo) do
    general =
      mediainfo
      |> get_in(["media", "track"])
      |> List.wrap()
      |> Enum.find(%{}, &(Map.get(&1, "@type") == "General"))

    format = Map.get(general, "Format", "") |> normalize_codec_string()

    cond do
      format == "iamf" ->
        raise %ClassificationError{reason: "IAMF container cannot be flattened to Matroska"}

      format == "bw64" ->
        raise %ClassificationError{reason: "ADM in BW64 cannot be flattened to Matroska"}

      true ->
        :ok
    end
  end

  defp raise_classification!(idx, track, reason) do
    raise %ClassificationError{
      track_index: idx,
      format: track.codec,
      codec_id: track.codec_id,
      reason: reason
    }
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
