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
  def changeset(video, attrs) do
    video
    |> cast(attrs, [:path, :size, :bitrate, :library_id, :mediainfo])
    |> validate_required([:path, :size])
    |> validate_media_info()
    |> unique_constraint(:path)
  end

  defp validate_media_info(changeset) do
    case get_change(changeset, :mediainfo, :no_mediainfo) do
      :no_mediainfo ->
        changeset

      mediainfo ->
        general =
          Enum.find(get_in(mediainfo, ["media", "track"]), fn x -> x["@type"] == "General" end)

        first_video =
          Enum.find(get_in(mediainfo, ["media", "track"]), fn x -> x["@type"] == "Video" end)

        # first_audio = Enum.find(get_in(mediainfo, ["media", "track"]), fn x -> x["@type"] == "Audio" end)

        {video_codecs, audio_codecs} =
          Enum.reduce(get_in(mediainfo, ["media", "track"]), {[], []}, fn x,
                                                                          {video_codecs,
                                                                           audio_codecs} ->
            case x["@type"] do
              "Video" -> {[x["CodecID"] | video_codecs], audio_codecs}
              "Audio" -> {video_codecs, [x["CodecID"] | audio_codecs]}
              _ -> {video_codecs, audio_codecs}
            end
          end)

        params = %{
          duration: get_in(general, ["Duration"]),
          bitrate: get_in(general, ["OverallBitRate"]),
          video_count: get_in(general, ["VideoCount"]),
          audio_count: get_in(general, ["AudioCount"]),
          text_count: get_in(general, ["TextCount"]),
          width: get_in(first_video, ["Width"]),
          height: get_in(first_video, ["Height"]),
          frame_rate: get_in(first_video, ["FrameRate"]),
          video_codecs: video_codecs,
          audio_codecs: audio_codecs
        }

        changeset
        |> cast(params, [
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
end
