defmodule Reencodarr.Media.Video do
  use Ecto.Schema
  import Ecto.Changeset

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
    field :video_codecs, {:array, :string}, default: []
    field :audio_codecs, {:array, :string}, default: []
    field :text_codecs, {:array, :string}, default: []

    field :mediainfo, :map

    belongs_to :library, Reencodarr.Media.Library

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(video \\ %__MODULE__{}, attrs) do
    video
    |> cast(attrs, [:path, :size, :bitrate, :library_id, :mediainfo])
    |> validate_required([:path, :size])
    |> validate_media_info()
    |> unique_constraint(:path)
  end

  defp validate_media_info(changeset) do
    case get_change(changeset, :mediainfo) do
      nil -> changeset
      mediainfo -> apply_media_info(changeset, mediainfo)
    end
  end

  defp apply_media_info(changeset, mediainfo) do
    general = Enum.find(mediainfo["media"]["track"], &(&1["@type"] == "General"))
    first_video = Enum.find(mediainfo["media"]["track"], &(&1["@type"] == "Video"))

    {video_codecs, audio_codecs} =
      Enum.reduce(mediainfo["media"]["track"], {[], []}, fn
        %{"@type" => "Video", "CodecID" => codec}, {vc, ac} -> {[codec | vc], ac}
        %{"@type" => "Audio", "CodecID" => codec}, {vc, ac} -> {vc, [codec | ac]}
        _, acc -> acc
      end)

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
      audio_codecs: audio_codecs
    }

    cast(changeset, params, [
      :duration,
      :bitrate,
      :width,
      :height,
      :frame_rate,
      :video_count,
      :audio_count,
      :text_count,
      :video_codecs,
      :audio_codecs
    ])
  end
end
