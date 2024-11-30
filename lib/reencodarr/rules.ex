defmodule Reencodarr.Rules do
  alias Reencodarr.Media

  @opus_codec_tag "A_OPUS"

  @recommended_opus_bitrates %{
    1 => 48,
    2 => 96,
    6 => 128,
    8 => 256
  }

  @spec apply(Media.Video.t()) :: keyword()
  def apply(video) do
    rules_to_apply = [
      &audio/1,
      &cuda/1,
      &hdr/1,
      &resolution/1,
      &video/1
    ]

    Keyword.new(Enum.flat_map(rules_to_apply, & &1.(video)))
  end

  @spec audio(Media.Video.t()) :: keyword()
  def audio(%Media.Video{atmos: false, max_audio_channels: channels, audio_codecs: audio_codecs}) do
    if @opus_codec_tag in audio_codecs do
      Keyword.new()
    else
      [
        {:"--acodec", "libopus"},
        {:"--enc", "b:a=#{opus_bitrate(channels)}k"},
        {:"--enc", "ac=#{channels}"}
      ]
    end
  end

  def audio(_), do: []

  defp opus_bitrate(channels) do
    Map.get(@recommended_opus_bitrates, channels, 512)
  end

  @spec cuda(any()) :: keyword()
  def cuda(_) do
    Keyword.new([{:"--enc-input", "hwaccel=cuda"}])
  end

  @spec grain(Media.Video.t(), integer()) :: keyword()
  def grain(%Media.Video{hdr: nil}, strength) do
    Keyword.new([{:"--svt", "film-grain=#{strength}:film-grain-denoise=0"}])
  end

  def grain(_, _), do: []

  @spec hdr(Media.Video.t()) :: keyword()
  def hdr(%Media.Video{hdr: nil}) do
    Keyword.new([{:"--svt", "tune=0"}])
  end

  def hdr(_) do
    Keyword.new([
      {:"--encoder", "libx265"},
      {:"--preset", "medium"}
    ])
  end

  @spec resolution(Media.Video.t()) :: keyword()
  def resolution(%Media.Video{height: height}) when height > 1080 do
    Keyword.new([{:"--vfilter", "scale=1920:-2"}])
  end

  def resolution(_) do
    Keyword.new()
  end

  @spec video(Media.Video.t()) :: keyword()
  def video(_) do
    Keyword.new([{:"--pix-format", "yuv420p10le"}])
  end
end
