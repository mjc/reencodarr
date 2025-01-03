defmodule Reencodarr.Media.Video do
  use Ecto.Schema
  import Ecto.Changeset

  alias Reencodarr.Media.CodecMapper

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

    {video_codecs, audio_codecs, atmos, max_audio_channels, frame_rate, height, width, hdr} =
      Enum.reduce(mediainfo["media"]["track"], {[], [], false, 0, 0.0, 0, 0, ""}, fn track, acc ->
        process_track(track, acc)
      end)

    reencoded = reencoded?(video_codecs, mediainfo)
    title = general["Title"] || Path.basename(get_field(changeset, :path))

    params = %{
      audio_codecs: audio_codecs,
      audio_count: general["AudioCount"],
      atmos: atmos,
      bitrate: general["OverallBitRate"],
      duration: general["Duration"],
      frame_rate: frame_rate,
      hdr: hdr,
      height: height,
      max_audio_channels: max_audio_channels,
      size: general["FileSize"],
      text_count: general["TextCount"],
      video_codecs: video_codecs,
      video_count: general["VideoCount"],
      width: width,
      reencoded: reencoded,
      title: title
    }

    changeset
    |> cast(params, @mediainfo_params)
    |> maybe_remove_size_zero()
    |> maybe_remove_bitrate_zero()
  end

  defp process_track(
         %{"@type" => "Video"} = track,
         {video_codecs, audio_codecs, atmos, max_audio_channels, _frame_rate, _height, _width,
          _hdr}
       ) do
    frame_rate = parse_float(track["FrameRate"], 0.0)
    height = parse_integer(track["Height"], 0)
    width = parse_integer(track["Width"], 0)

    hdr =
      parse_hdr([
        track["HDR_Format"],
        track["HDR_Format_Compatibility"],
        track["transfer_characteristics"]
      ])

    {
      [track["CodecID"] | video_codecs],
      audio_codecs,
      atmos,
      # Adjust as needed
      max_audio_channels,
      frame_rate,
      height,
      width,
      hdr
    }
  end

  defp process_track(
         %{"@type" => "Audio"} = track,
         {video_codecs, audio_codecs, atmos, max_audio_channels, frame_rate, height, width, hdr}
       ) do
    atmos_present =
      String.contains?(Map.get(track, "Format_AdditionalFeatures", ""), "JOC") ||
        String.contains?(Map.get(track, "Format_Commercial_IfAny", ""), "Atmos")

    channels = parse_integer(Map.get(track, "Channels", "0"), 0)

    {
      video_codecs,
      [Map.get(track, "CodecID") | audio_codecs],
      atmos || atmos_present,
      max(max_audio_channels, channels),
      frame_rate,
      height,
      width,
      hdr
    }
  end

  defp process_track(_track, acc), do: acc

  # Determine if the video has been reencoded
  @spec reencoded?(list(String.t()), map()) :: boolean()
  defp reencoded?(video_codecs, mediainfo) do
    Enum.any?([
      CodecMapper.has_av1_codec?(video_codecs),
      CodecMapper.has_opus_audio?(mediainfo),
      bitrate_and_resolution_low?(video_codecs, mediainfo),
      CodecMapper.has_low_resolution_hevc?(video_codecs, mediainfo)
    ])
  end

  defp bitrate_and_resolution_low?(video_codecs, mediainfo) do
    CodecMapper.low_bitrate_1080p?(video_codecs, mediainfo)
  end

  # Extract specific track information from mediainfo
  @spec get_track(map(), String.t()) :: map() | nil
  defp get_track(mediainfo, type) do
    Enum.find(mediainfo["media"]["track"], &(&1["@type"] == type))
  end

  defp parse_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> parsed
      :error -> default
    end
  end

  defp parse_float(value, _default), do: value

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> default
    end
  end

  defp parse_integer(value, _default), do: value

  defp parse_hdr(formats) do
    formats
    |> Enum.reduce([], fn format, acc ->
      if format &&
           (String.contains?(format, "Dolby Vision") || String.contains?(format, "HDR") ||
              String.contains?(format, "PQ") || String.contains?(format, "SMPTE")) do
        [format | acc]
      else
        acc
      end
    end)
    |> Enum.uniq()
    |> Enum.join(", ")
  end
end
