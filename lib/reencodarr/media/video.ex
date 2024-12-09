defmodule Reencodarr.Media.Video do
  use Ecto.Schema
  import Ecto.Changeset

  @type t() :: %__MODULE__{}

  @mediainfo_params [
    :duration,
    :bitrate,
    :width,
    :height,
    :frame_rate,
    :video_count,
    :audio_count,
    :text_count,
    :video_codecs,
    :audio_codecs,
    :max_audio_channels,
    :size,
    :hdr,
    :atmos,
    :reencoded,
    :title
  ]

  @optional [
    :bitrate,
    :library_id,
    :mediainfo,
    :reencoded
  ]

  @required [:path, :size]

  schema "videos" do
    field :atmos, :boolean
    field :audio_codecs, {:array, :string}, default: []
    field :audio_count, :integer
    field :bitrate, :integer
    field :duration, :float
    field :frame_rate, :float
    field :hdr, :string
    field :height, :integer
    field :max_audio_channels, :integer
    field :path, :string
    field :size, :integer
    field :text_codecs, {:array, :string}, default: []
    field :text_count, :integer
    field :video_codecs, {:array, :string}, default: []
    field :video_count, :integer
    field :width, :integer
    field :reencoded, :boolean, default: false
    field :title, :string

    field :mediainfo, :map

    belongs_to :library, Reencodarr.Media.Library

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(video \\ %__MODULE__{}, attrs) do
    video
    |> cast(attrs, @required ++ @optional)
    |> validate_media_info()
    |> validate_required(@required)
    |> unique_constraint(:path)
  end

  @spec validate_media_info(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp validate_media_info(changeset) do
    case get_change(changeset, :mediainfo) do
      nil -> changeset
      mediainfo -> apply_media_info(changeset, mediainfo)
    end
  end

  @spec apply_media_info(Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  defp apply_media_info(changeset, mediainfo) do
    general = get_track(mediainfo, "General")
    first_video = get_track(mediainfo, "Video")

    {video_codecs, audio_codecs} = extract_codecs(mediainfo)
    atmos = has_atmos_audio?(mediainfo)
    max_audio_channels = get_max_audio_channels(mediainfo)

    reencoded = reencoded?(video_codecs, mediainfo)

    title = general["Title"] || Path.basename(get_field(changeset, :path))

    params = %{
      audio_codecs: audio_codecs,
      audio_count: general["AudioCount"],
      atmos: atmos,
      bitrate: general["OverallBitRate"],
      duration: general["Duration"],
      frame_rate: first_video["FrameRate"],
      hdr: get_hdr_format(first_video),
      height: first_video["Height"],
      max_audio_channels: max_audio_channels,
      size: general["FileSize"],
      text_count: general["TextCount"],
      video_codecs: video_codecs,
      video_count: general["VideoCount"],
      width: first_video["Width"],
      reencoded: reencoded,
      title: title
    }

    changeset
    |> cast(params, @mediainfo_params)
  end

  @spec reencoded?(list(String.t()), map()) :: boolean()
  defp reencoded?(video_codecs, mediainfo) do
    has_av1_codec?(video_codecs) or
      has_opus_audio?(mediainfo) or
      is_low_bitrate_1080p?(video_codecs, mediainfo)
  end

  @spec has_av1_codec?(list(String.t())) :: boolean()
  defp has_av1_codec?(video_codecs) do
    Enum.any?(video_codecs, &(&1 == "V_AV1"))
  end

  @spec has_opus_audio?(map()) :: boolean()
  defp has_opus_audio?(mediainfo) do
    Enum.any?(mediainfo["media"]["track"], &audio_track_is_opus?/1)
  end

  @spec is_low_bitrate_1080p?(list(String.t()), map()) :: boolean()
  defp is_low_bitrate_1080p?(video_codecs, mediainfo) do
    "V_MPEGH/ISO/HEVC" in video_codecs and
      get_track(mediainfo, "Video")["Width"] == "1920" and
      String.to_integer(get_track(mediainfo, "General")["OverallBitRate"] || "0") < 5_000_000
  end

  @spec audio_track_is_opus?(map()) :: boolean()
  defp audio_track_is_opus?(%{"@type" => "Audio", "CodecID" => codec}) do
    codec == "A_OPUS"
  end

  defp audio_track_is_opus?(_), do: false

  @spec get_track(map(), String.t()) :: map() | nil
  defp get_track(mediainfo, type) do
    Enum.find(mediainfo["media"]["track"], &(&1["@type"] == type))
  end

  @spec extract_codecs(map()) :: {list(String.t()), list(String.t())}
  defp extract_codecs(mediainfo) do
    Enum.reduce(mediainfo["media"]["track"], {[], []}, fn
      %{"@type" => "Video", "CodecID" => codec}, {vc, ac} -> {[codec | vc], ac}
      %{"@type" => "Audio", "CodecID" => codec}, {vc, ac} -> {vc, [codec | ac]}
      _, acc -> acc
    end)
  end

  @spec get_hdr_format(map()) :: String.t()
  defp get_hdr_format(video_track) do
    formats = [video_track["HDR_Format"], video_track["HDR_Format_Compatibility"]]

    formats
    |> Enum.filter(&String.contains?(&1 || "", ["Dolby Vision", "HDR"]))
    |> Enum.uniq()
    |> Enum.join(", ")
  end

  @spec has_atmos_audio?(map()) :: boolean()
  defp has_atmos_audio?(mediainfo) do
    mediainfo["media"]["track"]
    |> Enum.any?(&audio_track_has_atmos?/1)
  end

  @spec audio_track_has_atmos?(map()) :: boolean()
  defp audio_track_has_atmos?(%{"@type" => "Audio"} = track) do
    additional_features = Map.get(track, "Format_AdditionalFeatures", "")
    commercial_format = Map.get(track, "Format_Commercial_IfAny", "")

    String.contains?(additional_features, "JOC") or String.contains?(commercial_format, "Atmos")
  end

  defp audio_track_has_atmos?(_), do: false

  @spec get_max_audio_channels(map()) :: integer()
  defp get_max_audio_channels(mediainfo) do
    mediainfo["media"]["track"]
    |> Enum.filter(&(&1["@type"] == "Audio"))
    |> Enum.map(&String.to_integer(&1["Channels"] || "0"))
    |> case do
      [] -> 0
      channels -> Enum.max(channels)
    end
  end
end
