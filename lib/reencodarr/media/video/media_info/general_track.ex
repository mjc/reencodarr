defmodule Reencodarr.Media.Video.MediaInfo.GeneralTrack do
  @moduledoc """
  Embedded schema for MediaInfo General track data.

  Contains overall file information like duration, file size, and overall bitrate.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Reencodarr.NumericParser

  @primary_key false
  embedded_schema do
    field :duration, :float
    field :file_size, :integer
    field :overall_bit_rate, :integer
    field :format, :string
    field :format_profile, :string
    field :file_extension, :string
    field :movie_name, :string
    field :track_name, :string

    # Raw data for debugging
    field :raw_data, :map, virtual: true
  end

  def changeset(track, attrs) do
    track
    |> cast(attrs, [])
    |> put_raw_data(attrs)
    |> convert_and_cast_fields(attrs)
    |> validate_required_fields()
  end

  defp put_raw_data(changeset, attrs) do
    put_change(changeset, :raw_data, attrs)
  end

  defp convert_and_cast_fields(changeset, attrs) do
    changeset
    |> put_converted_field(:duration, attrs, ["Duration", "duration"])
    |> put_converted_field(:file_size, attrs, ["FileSize", "file_size"])
    |> put_converted_field(:overall_bit_rate, attrs, ["OverallBitRate", "overall_bit_rate"])
    |> put_string_field(:format, attrs, ["Format", "format"])
    |> put_string_field(:format_profile, attrs, ["Format_Profile", "format_profile"])
    |> put_string_field(:file_extension, attrs, ["FileExtension", "file_extension"])
    |> put_string_field(:movie_name, attrs, ["MovieName", "movie_name"])
    |> put_string_field(:track_name, attrs, ["TrackName", "track_name"])
  end

  defp put_converted_field(changeset, target_field, attrs, source_fields) do
    # Try each source field until we find a non-nil value
    value = find_and_convert_numeric(attrs, source_fields)
    put_change(changeset, target_field, value)
  end

  defp put_string_field(changeset, field_name, attrs, possible_keys) do
    case find_string_value(attrs, possible_keys) do
      nil -> changeset
      value -> put_change(changeset, field_name, value)
    end
  end

  defp find_and_convert_numeric(attrs, possible_keys) do
    possible_keys
    |> Enum.find_value(fn key ->
      case Map.get(attrs, key) do
        nil -> nil
        value when is_number(value) -> value
        value when is_binary(value) -> NumericParser.parse_general_numeric(value)
        _ -> nil
      end
    end)
  end

  defp find_string_value(attrs, possible_keys) do
    possible_keys
    |> Enum.find_value(fn key ->
      case Map.get(attrs, key) do
        nil -> nil
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp validate_required_fields(changeset) do
    Reencodarr.Validation.validate_required_field(changeset, :duration, "duration is required for general track")
  end
end
