defmodule Reencodarr.Rules do
  alias Reencodarr.Media

  @opus_codec_tag "A_OPUS"

  @recommended_opus_bitrates %{
    1 => 48,
    2 => 96,
    6 => 128,
    8 => 256
  }

  @spec audio(Reencodarr.Media.Video.t()) :: keyword(String.t())
  def audio(%Media.Video{atmos: false, max_audio_channels: channels, audio_codecs: audio_codecs}) do
    maybe_opus = get_opus_codec_options(audio_codecs, channels)
    Keyword.new(maybe_opus)
  end

  defp get_opus_codec_options(audio_codecs, channels) do
    if @opus_codec_tag in audio_codecs do
      []
    else
      opus_arguments(channels)
    end
  end

  defp opus_arguments(channels) do
    [
      {"--acodec", "libopus"},
      {"--enc", "b:a=#{opus_bitrate(channels)}k"},
      {"--enc", "ac=#{channels}"}
    ]
  end

  defp opus_bitrate(channels) do
    case @recommended_opus_bitrates[channels] do
      bitrate when is_integer(bitrate) -> bitrate
      _ -> 512
    end
  end

  # TODO: detect CUDA capabilities
  @spec cuda(Media.Video.t()) :: keyword(String.t())
  def cuda(_) do
    Keyword.new({"--enc-input", "hwaccel=cuda"})
  end

  # TODO: figure out how to detect grain or ask for that to be added to ab-av1
  @spec grain(Reencodarr.Media.Video.t(), integer) :: keyword(String.t())
  def grain(%Media.Video{hdr: hdr}, strength) when is_nil(hdr) do
    Keyword.new({"--svt", "film-grain=#{strength}:film-grain-denoise=0"})
  end

  def grain(_), do: Keyword.new()

  @doc """
    My devices don't support av1 and get re-encoded by plex.
    So for now I am using x265 for HDR and av1 for everything else.
  """
  @spec hdr(Media.Video.t()) :: keyword(String.t())
  def hdr(%Media.Video{hdr: hdr}) when is_nil(hdr) do
    Keyword.new([{"--svt", "tune=0"}])
  end

  def hdr(_) do
    Keyword.new([{"--encoder", "libx265"}, {"--preset", "medium"}])
  end

  @spec resolution(Reencodarr.Media.Video.t()) :: keyword(String.t())
  def resolution(%Media.Video{width: width}) when width > 1080 do
    Keyword.new({"--vfilter", "scale=1920:-2"})
  end

  def resolution(%Media.Video{width: width}) when width <= 1080 do
    Keyword.new()
  end

  @spec video(Reencodarr.Media.Video.t()) :: keyword(String.t())
  def video(%Media.Video{}) do
    Keyword.new({"--pix-format", "yuv420p10le"})
  end
end
