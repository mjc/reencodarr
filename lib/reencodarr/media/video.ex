defmodule Reencodarr.Media.Video do
  use Ecto.Schema
  import Ecto.Changeset
  alias Reencodarr.Media.MediaInfoExtractor

  @moduledoc "Represents video metadata and schema."

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
    :text_codecs,
    :hdr,
    :title,
    :content_year
  ]

  @optional [
    :bitrate,
    :library_id,
    :mediainfo,
    :service_id,
    :service_type,
    :duration,
    :width,
    :height,
    :frame_rate,
    :video_count,
    :audio_count,
    :text_count,
    :text_codecs,
    :hdr,
    :title,
    :content_year,
    :max_audio_channels,
    :atmos
  ]

  @required [
    :path,
    :state,
    :video_codecs,
    :audio_codecs,
    :size
  ]

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
    field :title, :string
    field :service_id, :string
    field :service_type, Ecto.Enum, values: @service_types
    field :mediainfo, :map

    # Year information from Sonarr/Radarr APIs
    # Content year: movie release year, TV series start year, or episode air year
    field :content_year, :integer

    field :state, Ecto.Enum,
      values: [
        :needs_analysis,
        :analyzed,
        :crf_searching,
        :crf_searched,
        :encoding,
        :encoded,
        :failed
      ],
      default: :needs_analysis

    belongs_to :library, Reencodarr.Media.Library
    has_many :vmafs, Reencodarr.Media.Vmaf
    has_many :failures, Reencodarr.Media.VideoFailure

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(video \\ %__MODULE__{}, attrs) do
    video
    |> cast(attrs, @required ++ @optional)
    |> validate_media_info()
    |> validate_audio_fields()
    |> maybe_remove_size_zero()
    |> maybe_remove_bitrate_zero()
    |> validate_required(@required)
    |> unique_constraint(:path)
    |> validate_inclusion(:service_type, @service_types)
    |> validate_number(:bitrate, greater_than_or_equal_to: 1)
  end

  defp maybe_remove_size_zero(changeset) do
    case get_change(changeset, :size) do
      0 -> update_size_from_file(changeset)
      _ -> changeset
    end
  end

  defp update_size_from_file(changeset) do
    path = get_field(changeset, :path)

    if path && File.exists?(path) do
      update_size_from_existing_file(changeset, path)
    else
      # Keep the 0 value rather than failing validation
      changeset
    end
  end

  defp update_size_from_existing_file(changeset, path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: file_size}} when file_size > 0 ->
        put_change(changeset, :size, file_size)

      _ ->
        # Keep the 0 value rather than failing validation
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

  defp validate_media_info(changeset) do
    case get_change(changeset, :mediainfo) do
      nil ->
        changeset

      mediainfo ->
        # Use the simpler extractor that avoids complex track traversal
        params = MediaInfoExtractor.extract_video_params(mediainfo, get_field(changeset, :path))

        changeset
        |> cast(params, @mediainfo_params)
        |> maybe_remove_size_zero()
        |> maybe_remove_bitrate_zero()
    end
  end

  defp validate_audio_fields(changeset) do
    changeset
    |> validate_number(:max_audio_channels, greater_than_or_equal_to: 0, less_than: 32)
    |> validate_number(:audio_count, greater_than_or_equal_to: 0)
    |> validate_audio_codecs_consistency()
  end

  defp validate_audio_codecs_consistency(changeset) do
    audio_count = get_field(changeset, :audio_count) || 0
    audio_codecs = get_field(changeset, :audio_codecs) || []

    # If audio_count > 0, we should have audio_codecs
    if audio_count > 0 and Enum.empty?(audio_codecs) do
      add_error(changeset, :audio_codecs, "should not be empty when audio tracks are present")
    else
      changeset
    end
  end
end
