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
    :title,
    :failed
  ]

  @optional [
    :bitrate,
    :library_id,
    :mediainfo,
    :reencoded,
    :service_id,
    :service_type,
    :failed
  ]

  @required [:path, :size]

  @service_types [:sonarr, :radarr]

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
    field :service_id, :string
    field :service_type, Ecto.Enum, values: @service_types
    field :mediainfo, :map
    field :failed, :boolean, default: false

    belongs_to :library, Reencodarr.Media.Library
    has_many :vmafs, Reencodarr.Media.Vmaf

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(video \\ %__MODULE__{}, attrs) do
    video
    |> cast(attrs, @required ++ @optional)
    |> validate_media_info()
    |> maybe_remove_size_zero()
    |> maybe_remove_bitrate_zero()
    |> validate_required(@required)
    |> unique_constraint(:path)
    |> validate_inclusion(:service_type, @service_types)
    |> validate_number(:bitrate, greater_than_or_equal_to: 1)
  end

  defp maybe_remove_size_zero(changeset) do
    if get_change(changeset, :size) == 0 do
      delete_change(changeset, :size)
    else
      changeset
    end
  end

  defp maybe_remove_bitrate_zero(changeset) do
    if get_change(changeset, :bitrate) == 0 do
      delete_change(changeset, :bitrate)
    else
      changeset
    end
  end

  # Validate media info and apply changes
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

  # Determine if the video has been reencoded
  @spec reencoded?(list(String.t()), map()) :: boolean()
  defp reencoded?(video_codecs, mediainfo) do
    has_av1_codec?(video_codecs) or
      has_opus_audio?(mediainfo) or
      is_low_bitrate_1080p?(video_codecs, mediainfo) or
      is_low_resolution_hevc?(video_codecs, mediainfo)
  end

  # Check for specific codec and resolution conditions
  @spec is_low_resolution_hevc?(list(String.t()), map()) :: boolean()
  defp is_low_resolution_hevc?(video_codecs, mediainfo) do
    Enum.member?(video_codecs, "V_MPEGH/ISO/HEVC") and
      get_track(mediainfo, "Video")["Height"]
      |> to_string()
      |> String.to_integer() < 720
  end

  @spec has_av1_codec?(list(String.t())) :: boolean()
  defp has_av1_codec?(video_codecs) do
    Enum.member?(video_codecs, "V_AV1")
  end

  @spec has_opus_audio?(map()) :: boolean()
  defp has_opus_audio?(mediainfo) do
    Enum.any?(mediainfo["media"]["track"], &audio_track_is_opus?/1)
  end

  @spec is_low_bitrate_1080p?(list(String.t()), map()) :: boolean()
  defp is_low_bitrate_1080p?(video_codecs, mediainfo) do
    Enum.member?(video_codecs, "V_MPEGH/ISO/HEVC") and
      get_track(mediainfo, "Video")["Width"] == "1920" and
      String.to_integer(get_track(mediainfo, "General")["OverallBitRate"] || "0") < 20_000_000
  end

  # Check if audio track is Opus
  @spec audio_track_is_opus?(map()) :: boolean()
  defp audio_track_is_opus?(%{"@type" => "Audio", "CodecID" => "A_OPUS"}), do: true
  defp audio_track_is_opus?(_), do: false

  # Extract specific track information from mediainfo
  @spec get_track(map(), String.t()) :: map() | nil
  defp get_track(mediainfo, type) do
    Enum.find(mediainfo["media"]["track"], &(&1["@type"] == type))
  end

  # Extract video and audio codecs from mediainfo
  @spec extract_codecs(map()) :: {list(String.t()), list(String.t())}
  defp extract_codecs(mediainfo) do
    Enum.reduce(mediainfo["media"]["track"], {[], []}, fn
      %{"@type" => "Video", "CodecID" => codec}, {vc, ac} -> {[codec | vc], ac}
      %{"@type" => "Audio", "CodecID" => codec}, {vc, ac} -> {vc, [codec | ac]}
      _, acc -> acc
    end)
  end

  # Get HDR format from video track
  @spec get_hdr_format(map()) :: String.t()
  defp get_hdr_format(video_track) do
    [video_track["HDR_Format"], video_track["HDR_Format_Compatibility"]]
    |> Enum.filter(&String.contains?(&1 || "", ["Dolby Vision", "HDR"]))
    |> Enum.uniq()
    |> Enum.join(", ")
  end

  # Check if any audio track has Atmos
  @spec has_atmos_audio?(map()) :: boolean()
  defp has_atmos_audio?(mediainfo) do
    Enum.any?(mediainfo["media"]["track"], &audio_track_has_atmos?/1)
  end

  @spec audio_track_has_atmos?(map()) :: boolean()
  defp audio_track_has_atmos?(%{"@type" => "Audio"} = track) do
    additional_features = Map.get(track, "Format_AdditionalFeatures", "")
    commercial_format = Map.get(track, "Format_Commercial_IfAny", "")

    String.contains?(additional_features || "", "JOC") or
      String.contains?(commercial_format || "", "Atmos")
  end

  defp audio_track_has_atmos?(_), do: false

  # Get the maximum number of audio channels from mediainfo
  @spec get_max_audio_channels(map()) :: integer()
  defp get_max_audio_channels(mediainfo) do
    mediainfo["media"]["track"]
    |> Enum.filter(&(&1["@type"] == "Audio"))
    |> Enum.map(&String.to_integer(&1["Channels"] || "0"))
    |> Enum.max(fn -> 0 end)
  end
end
