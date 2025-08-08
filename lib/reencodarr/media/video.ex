defmodule Reencodarr.Media.Video do
  use Ecto.Schema
  import Ecto.Changeset
  alias Reencodarr.Media.Video.MediaInfo, as: EmbeddedMediaInfo

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
    has_many :failures, Reencodarr.Media.VideoFailure

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(video \\ %__MODULE__{}, attrs) do
    video
    |> cast(attrs, @required ++ @optional)
    |> validate_mediainfo_with_embedded_schema()
    |> maybe_remove_size_zero()
    |> maybe_remove_bitrate_zero()
    |> validate_required(@required)
    |> unique_constraint(:path)
    |> validate_inclusion(:service_type, @service_types)
    |> validate_number(:bitrate, greater_than_or_equal_to: 1)
  end

  # Validate mediainfo using embedded schema and populate flat fields
  defp validate_mediainfo_with_embedded_schema(changeset) do
    case get_change(changeset, :mediainfo) do
      nil -> changeset
      mediainfo -> process_mediainfo_validation(changeset, mediainfo)
    end
  end

  defp process_mediainfo_validation(changeset, mediainfo) do
    case EmbeddedMediaInfo.from_json(mediainfo) do
      {:ok, parsed_mediainfo} -> extract_and_apply_video_params(changeset, parsed_mediainfo)
      {:error, reason} -> add_error(changeset, :mediainfo, "Invalid MediaInfo format: #{reason}")
    end
  end

  defp extract_and_apply_video_params(changeset, parsed_mediainfo) do
    case EmbeddedMediaInfo.to_video_params(parsed_mediainfo) do
      {:ok, video_params} ->
        apply_video_params_to_changeset(changeset, video_params)

      {:error, reason} ->
        add_error(changeset, :mediainfo, "MediaInfo validation failed: #{reason}")
    end
  end

  defp apply_video_params_to_changeset(changeset, video_params) do
    # Add title from path since it's not in MediaInfo
    path = get_field(changeset, :path)
    title = if path, do: extract_title_from_path(path), else: nil

    # Ensure we have a size field - get from filesystem if not in MediaInfo
    final_params =
      video_params
      |> Map.put("title", title)
      |> ensure_size_field(path)

    # Cast the validated parameters to the flat fields
    cast(changeset, final_params, @mediainfo_params)
  end

  defp ensure_size_field(params, path) do
    case Map.get(params, "size") do
      nil ->
        # No size in MediaInfo, try to get from filesystem
        get_size_from_filesystem(params, path)

      size when is_integer(size) and size > 0 ->
        # Valid size from MediaInfo
        params

      _ ->
        # Invalid size (0 or something else), try filesystem
        get_size_from_filesystem(params, path)
    end
  end

  defp get_size_from_filesystem(params, path) do
    if path && File.exists?(path) do
      get_file_size_or_default(params, path)
    else
      Map.put(params, "size", 0)
    end
  end

  defp get_file_size_or_default(params, path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: file_size}} ->
        Map.put(params, "size", file_size)

      _ ->
        Map.put(params, "size", 0)
    end
  end

  defp extract_title_from_path(path) when is_binary(path) do
    path
    |> Path.basename()
    |> Path.rootname()
  end

  defp extract_title_from_path(_), do: nil

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
end
