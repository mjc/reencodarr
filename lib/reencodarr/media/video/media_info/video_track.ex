defmodule Reencodarr.Media.Video.MediaInfo.VideoTrack do
  @moduledoc """
  Embedded schema for MediaInfo Video track data.

  Contains video-specific information like resolution, codec, frame rate, and HDR metadata.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Reencodarr.NumericParser
  alias Reencodarr.ChangesetHelpers

  @primary_key false
  embedded_schema do
    field :format, :string
    field :format_profile, :string
    field :format_level, :string
    field :width, :integer
    field :height, :integer
    field :frame_rate, :float
    field :bit_rate, :integer
    field :duration, :float

    # HDR-related fields
    field :color_space, :string
    field :color_primaries, :string
    field :transfer_characteristics, :string
    field :matrix_coefficients, :string
    field :hdr_format, :string
    field :hdr_format_commercial, :string

    # Advanced video properties
    field :scan_type, :string
    field :display_aspect_ratio, :string
    field :pixel_aspect_ratio, :string
    field :frame_rate_mode, :string

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
    |> put_string_field(:format, attrs, ["Format", "format"])
    |> put_string_field(:format_profile, attrs, ["Format_Profile", "format_profile"])
    |> put_string_field(:format_level, attrs, ["Format_Level", "format_level"])
    |> put_converted_field(:width, attrs, ["Width", "width"])
    |> put_converted_field(:height, attrs, ["Height", "height"])
    |> put_converted_field(:frame_rate, attrs, ["FrameRate", "frame_rate"])
    |> put_converted_field(:bit_rate, attrs, ["BitRate", "bit_rate"])
    |> put_converted_field(:duration, attrs, ["Duration", "duration"])
    |> put_string_field(:color_space, attrs, ["ColorSpace", "color_space"])
    |> put_string_field(:color_primaries, attrs, [
      "colour_primaries",
      "ColorPrimaries",
      "color_primaries"
    ])
    |> put_string_field(:transfer_characteristics, attrs, [
      "transfer_characteristics",
      "TransferCharacteristics",
      "transfer_characteristics"
    ])
    |> put_string_field(:matrix_coefficients, attrs, [
      "matrix_coefficients",
      "MatrixCoefficients",
      "matrix_coefficients"
    ])
    |> put_string_field(:hdr_format, attrs, ["HDR_Format", "hdr_format"])
    |> put_string_field(:hdr_format_commercial, attrs, [
      "HDR_Format_Commercial",
      "hdr_format_commercial"
    ])
    |> put_string_field(:scan_type, attrs, ["ScanType", "scan_type"])
    |> put_string_field(:display_aspect_ratio, attrs, [
      "DisplayAspectRatio",
      "display_aspect_ratio"
    ])
    |> put_string_field(:pixel_aspect_ratio, attrs, ["PixelAspectRatio", "pixel_aspect_ratio"])
    |> put_string_field(:frame_rate_mode, attrs, ["FrameRate_Mode", "frame_rate_mode"])
  end

  defp put_converted_field(changeset, field_name, attrs, possible_keys) do
    case find_and_convert_numeric(attrs, possible_keys) do
      nil -> changeset
      value -> put_change(changeset, field_name, value)
    end
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
        value when is_binary(value) -> NumericParser.parse_video_numeric(value)
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
    changeset
    |> ChangesetHelpers.validate_field_present(:format, "video format is required")
    |> ChangesetHelpers.validate_resolution_present()
  end
end
