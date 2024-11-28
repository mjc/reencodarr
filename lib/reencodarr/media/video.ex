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
    :size,
    :hdr,
    :atmos
  ]

  @optional [
    :bitrate,
    :library_id,
    :mediainfo
  ]

  @required [:path, :size]

  schema "videos" do
    field :size, :integer
    field :path, :string
    field :bitrate, :integer
    field :duration, :float
    field :width, :integer
    field :height, :integer
    field :frame_rate, :float
    field :video_count, :integer
    field :audio_count, :integer
    field :text_count, :integer
    field :hdr, :string
    field :atmos, :boolean
    field :video_codecs, {:array, :string}, default: []
    field :audio_codecs, {:array, :string}, default: []
    field :text_codecs, {:array, :string}, default: []

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

    params = %{
      duration: general["Duration"],
      bitrate: general["OverallBitRate"],
      video_count: general["VideoCount"],
      audio_count: general["AudioCount"],
      text_count: general["TextCount"],
      width: first_video["Width"],
      height: first_video["Height"],
      frame_rate: first_video["FrameRate"],
      video_codecs: video_codecs,
      audio_codecs: audio_codecs,
      size: general["FileSize"],
      hdr: get_hdr_format(first_video),
      atmos: atmos
    }

    cast(changeset, params, @mediainfo_params)
  end

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
end
