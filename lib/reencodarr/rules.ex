defmodule Reencodarr.Rules do
  alias Reencodarr.Media

  @opus_codec_tag "A_OPUS"

  @recommended_opus_bitrates %{
    1 => 48,
    2 => 96,
    6 => 128,
    8 => 256
  }

  # I kind of hate this but it's less gross looking than my other ideas.
  @spec apply(Reencodarr.Media.Video.t()) :: keyword(String.t())
  def apply(%Media.Video{} = video) do
    {[], video}
    |> audio()
    |> cuda()
    # |> grain(5)
    |> hdr()
    |> resolution()
    |> video()
    |> elem(0)
  end

  @spec audio({keyword(String.t()), Reencodarr.Media.Video.t()}) :: {keyword(String.t()), Reencodarr.Media.Video.t()}
  def audio({opts, %Media.Video{atmos: false, max_audio_channels: channels, audio_codecs: audio_codecs} = video}) do
    maybe_opus = get_opus_codec_options(audio_codecs, channels)
    {opts ++ Keyword.new(maybe_opus), video}
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
      {:"--acodec", "libopus"},
      {:"--enc", "b:a=#{opus_bitrate(channels)}k"},
      {:"--enc", "ac=#{channels}"}
    ]
  end

  defp opus_bitrate(channels) do
    case @recommended_opus_bitrates[channels] do
      bitrate when is_integer(bitrate) -> bitrate
      _ -> 512
    end
  end

  # TODO: detect CUDA capabilities
  @spec cuda({keyword(String.t()), Media.Video.t()}) :: {keyword(String.t()), Media.Video.t()}
  def cuda({opts, video}) do
    {opts ++ Keyword.new([{:"--enc-input", "hwaccel=cuda"}]), video}
  end

  # TODO: figure out how to detect grain or ask for that to be added to ab-av1
  @spec grain({keyword(String.t()), Reencodarr.Media.Video.t()}, integer) :: {keyword(String.t()), Reencodarr.Media.Video.t()}
  def grain({opts, %Media.Video{hdr: hdr} = video}, strength) when is_nil(hdr) do
    {opts ++ Keyword.new({:"--svt", "film-grain=#{strength}:film-grain-denoise=0"}), video}
  end

  def grain({opts, video}, _), do: {opts, video}

  @doc """
    My devices don't support av1 and get re-encoded by plex.
    So for now I am using x265 for HDR and av1 for everything else.
  """
  @spec hdr({keyword(String.t()), Media.Video.t()}) :: {keyword(String.t()), Media.Video.t()}
  def hdr({opts, %Media.Video{hdr: hdr} = video}) when is_nil(hdr) do
    {opts ++ Keyword.new([{:"--svt", "tune=0"}]), video}
  end

  def hdr({opts, video}) do
    {opts ++ Keyword.new([{:"--encoder", "libx265"}, {:"--preset", "medium"}]), video}
  end

  @spec resolution({keyword(String.t()), Reencodarr.Media.Video.t()}) :: {keyword(String.t()), Reencodarr.Media.Video.t()}
  def resolution({opts, %Media.Video{width: width} = video}) when width > 1080 do
    {opts ++ Keyword.new([{:"--vfilter", "scale=1920:-2"}]), video}
  end

  def resolution({opts, %Media.Video{width: width} = video}) when width <= 1080 do
    {opts, video}
  end

  @spec video({keyword(String.t()), Reencodarr.Media.Video.t()}) :: {keyword(String.t()), Reencodarr.Media.Video.t()}
  def video({opts, %Media.Video{} = video}) do
    {opts ++ Keyword.new([{:"--pix-format", "yuv420p10le"}]), video}
  end
end
