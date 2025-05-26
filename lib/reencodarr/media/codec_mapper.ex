defmodule Reencodarr.Media.CodecMapper do
  @codec_id_map %{
    "AV1" => "V_AV1",
    "x265" => "V_MPEGH/ISO/HEVC",
    "h265" => "V_MPEGH/ISO/HEVC",
    "HEVC" => "V_MPEGH/ISO/HEVC",
    "VP9" => "V_VP9",
    "VP8" => "V_VP8",
    "x264" => "V_MPEG4/ISO/AVC",
    "h264" => "V_MPEG4/ISO/AVC",
    "AVC" => "V_MPEG4/ISO/AVC",
    "XviD" => "V_XVID",
    "VC1" => "V_VC1",
    "DivX" => "V_DIVX",
    "MPEG2" => "V_MPEG2",
    "EAC3 Atmos" => :eac3_atmos,
    "TrueHD Atmos" => :truehd_atmos,
    "Opus" => "A_OPUS",
    "EAC3" => "A_EAC3",
    "TrueHD" => "A_TRUEHD",
    "DTS-X" => "A_DTS/X",
    "DTS-HD MA" => "A_DTS/MA",
    "DTS-HD HRA" => "A_DTS",
    "DTS" => "A_DTS",
    "DTS-ES" => "A_DTS/ES",
    "FLAC" => "A_FLAC",
    "Vorbis" => "A_VORBIS",
    "AAC" => "A_AAC",
    "AC3" => "A_AC3",
    "MP3" => "A_MPEG/L3",
    "MP2" => "A_MPEG/L2",
    "PCM" => "A_PCM",
    "" => "",
    nil => ""
  }

  @channel_map %{
    "9.2" => 11,
    "9.1" => 10,
    "8.2" => 10,
    "8.1" => 9,
    "8" => 8,
    "7.2" => 9,
    "7.1" => 8,
    "6.1" => 7,
    "6" => 6,
    "5.1" => 6,
    "5" => 5,
    "4.1" => 5,
    "4" => 4,
    "3.1" => 4,
    "3" => 3,
    "2.1" => 3,
    "2" => 2,
    "1" => 1
  }

  alias Reencodarr.Media.CodecHelper

  @spec map_codec_id(String.t() | nil) :: String.t() | atom()
  def map_codec_id(codec) do
    Map.fetch!(@codec_id_map, codec)
  end

  @spec has_av1_codec?(list(String.t())) :: boolean()
  def has_av1_codec?(video_codecs), do: "V_AV1" in video_codecs || "AV1" in video_codecs

  @spec has_opus_audio?(map()) :: boolean()
  def has_opus_audio?(mediainfo) do
    Enum.any?(mediainfo["media"]["track"], &audio_track_is_opus?/1)
  end

  @spec has_low_resolution_hevc?(list(String.t()), map()) :: boolean()
  def has_low_resolution_hevc?(video_codecs, mediainfo) do
    height = CodecHelper.get_int(mediainfo, "Video", "Height")

    case height do
      0 ->
        false

      _ ->
        "V_MPEGH/ISO/HEVC" in video_codecs and
          CodecHelper.get_int(mediainfo, "Video", "Height") < 720
    end
  end

  @spec low_bitrate_1080p?(list(String.t()), map()) :: boolean()
  def low_bitrate_1080p?(video_codecs, mediainfo) do
    "V_MPEGH/ISO/HEVC" in video_codecs and
      CodecHelper.get_int(mediainfo, "Video", "Width") == 1920 and
      CodecHelper.get_int(mediainfo, "General", "OverallBitRate") < 20_000_000
  end

  @spec audio_track_is_opus?(map()) :: boolean()
  def audio_track_is_opus?(%{"@type" => "Audio", "Format" => "Opus"}), do: true
  def audio_track_is_opus?(%{"@type" => "Audio", "CodecID" => "A_OPUS"}), do: true
  def audio_track_is_opus?(_), do: false

  @spec map_channels(String.t() | float()) :: integer()
  def map_channels(channel) do
    Map.get(@channel_map, to_string(channel), 0)
  end

  @spec format_commercial_if_any(String.t() | any) :: String.t()
  def format_commercial_if_any(atmos) when atmos in ["TrueHD Atmos", "EAC3 Atmos", "DTS-X"],
    do: "Atmos"

  def format_commercial_if_any(_), do: ""
end
