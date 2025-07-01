defmodule Reencodarr.Rules do
  alias Reencodarr.Media

  @opus_codec_tag "A_OPUS"

  @recommended_opus_bitrates %{
    1 => 48,     # Mono - official recommendation
    2 => 96,     # Stereo - official recommendation
    3 => 160,    # 2.1 or 3.0 - (~53 kbps per channel)
    4 => 192,    # 4.0 or 3.1 - (~48 kbps per channel)
    5 => 224,    # 5.0 or 4.1 - (~45 kbps per channel)
    6 => 256,    # 5.1 - official recommendation (~43 kbps per channel)
    7 => 320,    # 6.1 - (~46 kbps per channel)
    8 => 450,    # 7.1 - official recommendation (~56 kbps per channel)
    9 => 500,    # 8.1 - (~56 kbps per channel)
    10 => 510,   # 9.1 - Max supported bitrate
    11 => 510    # 9.2 - Max supported bitrate
  }

  @spec apply(Media.Video.t()) :: list()
  def apply(video) do
    rules_to_apply = [
      &audio/1,
      # &cuda/1,
      &hdr/1,
      &resolution/1,
      &video/1
    ]

    Enum.flat_map(rules_to_apply, & &1.(video))
  end

  @spec audio(Media.Video.t()) :: list()
  def audio(%Media.Video{atmos: false, max_audio_channels: channels, audio_codecs: audio_codecs}) do
    if @opus_codec_tag in audio_codecs do
      []
    else
      if channels == 3 do
        [
          {"--acodec", "libopus"},
          {"--enc", "b:a=128k"},
          # Upmix to 5.1
          {"--enc", "ac=6"}
        ]
      else
        [
          {"--acodec", "libopus"},
          {"--enc", "b:a=#{opus_bitrate(channels)}k"},
          {"--enc", "ac=#{channels}"}
        ]
      end
    end
  end

  def audio(_), do: []

  defp opus_bitrate(channels) when channels > 11 do
    # For very high channel counts, use maximum supported bitrate
    510
  end

  defp opus_bitrate(channels) do
    # Use ~64 kbps per channel as fallback for unmapped channel counts
    Map.get(@recommended_opus_bitrates, channels, min(510, channels * 64))
  end

  @spec cuda(any()) :: list()
  def cuda(_) do
    [{"--enc-input", "hwaccel=cuda"}]
  end

  @spec grain(Media.Video.t(), integer()) :: list()
  def grain(%Media.Video{hdr: nil}, strength) do
    [{"--svt", "film-grain=#{strength}:film-grain-denoise=0"}]
  end

  def grain(_, _), do: []

  @spec hdr(Media.Video.t()) :: list()
  def hdr(%Media.Video{hdr: hdr}) when not is_nil(hdr) do
    [
      {"--svt", "tune=0"},
      # Add Dolby Vision for HDR content
      {"--svt", "dolbyvision=1"}
    ]
  end

  def hdr(_) do
    [{"--svt", "tune=0"}]
  end

  @spec resolution(Media.Video.t()) :: list()
  def resolution(%Media.Video{height: height}) when height > 1080 do
    [{"--vfilter", "scale=1920:-2"}]
  end

  def resolution(_) do
    []
  end

  @spec video(Media.Video.t()) :: list()
  def video(_) do
    [{"--pix-format", "yuv420p10le"}]
  end
end
