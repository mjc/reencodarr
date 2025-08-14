defmodule Reencodarr.Media.Video.MediaInfo.AudioTrack do
  @moduledoc """
  Embedded schema for MediaInfo Audio track data.

  Contains audio-specific information like codec, channels, bitrate, and Atmos detection.
  This schema includes comprehensive validation to prevent the invalid audio arguments
  issue that was causing encoding failures.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Reencodarr.NumericParser

  @primary_key false
  embedded_schema do
    field :format, :string
    field :format_profile, :string
    field :format_commercial_if_any, :string
    field :format_additionalfeatures, :string
    field :channels, :integer
    field :channel_layout, :string
    field :bit_rate, :integer
    field :sampling_rate, :integer
    field :duration, :float
    field :language, :string
    field :title, :string
    field :default, :boolean
    field :forced, :boolean

    # Atmos and spatial audio detection
    field :compression_mode, :string
    field :service_kind, :string

    # Raw data for debugging
    field :raw_data, :map, virtual: true
  end

  def changeset(track, attrs) do
    track
    |> cast(attrs, [])
    |> put_raw_data(attrs)
    |> convert_and_cast_fields(attrs)
    |> validate_required_fields()
    |> validate_channel_consistency()
  end

  defp put_raw_data(changeset, attrs) do
    put_change(changeset, :raw_data, attrs)
  end

  defp convert_and_cast_fields(changeset, attrs) do
    changeset
    |> put_string_field(:format, attrs, ["Format", "format"])
    |> put_string_field(:format_profile, attrs, ["Format_Profile", "format_profile"])
    |> put_string_field(:format_commercial_if_any, attrs, [
      "Format_Commercial_IfAny",
      "format_commercial_if_any"
    ])
    |> put_string_field(:format_additionalfeatures, attrs, [
      "Format_AdditionalFeatures",
      "format_additionalfeatures"
    ])
    |> put_converted_field(:channels, attrs, ["Channels", "channels", "Channel(s)"])
    |> put_string_field(:channel_layout, attrs, [
      "ChannelLayout",
      "channel_layout",
      "Channel(s)_Original"
    ])
    |> put_converted_field(:bit_rate, attrs, ["BitRate", "bit_rate"])
    |> put_converted_field(:sampling_rate, attrs, ["SamplingRate", "sampling_rate"])
    |> put_converted_field(:duration, attrs, ["Duration", "duration"])
    |> put_string_field(:language, attrs, ["Language", "language"])
    |> put_string_field(:title, attrs, ["Title", "title"])
    |> put_boolean_field(:default, attrs, ["Default", "default"])
    |> put_boolean_field(:forced, attrs, ["Forced", "forced"])
    |> put_string_field(:compression_mode, attrs, ["Compression_Mode", "compression_mode"])
    |> put_string_field(:service_kind, attrs, ["ServiceKind", "service_kind"])
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

  defp put_boolean_field(changeset, field_name, attrs, possible_keys) do
    case find_boolean_value(attrs, possible_keys) do
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
        value when is_binary(value) -> NumericParser.parse_audio_numeric(value)
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

  defp find_boolean_value(attrs, possible_keys) do
    possible_keys
    |> Enum.find_value(fn key ->
      attrs
      |> Map.get(key)
      |> parse_boolean_value()
    end)
  end

  defp parse_boolean_value(nil), do: nil
  defp parse_boolean_value(value) when is_boolean(value), do: value
  defp parse_boolean_value("Yes"), do: true
  defp parse_boolean_value("No"), do: false
  defp parse_boolean_value("true"), do: true
  defp parse_boolean_value("false"), do: false
  defp parse_boolean_value("1"), do: true
  defp parse_boolean_value("0"), do: false
  defp parse_boolean_value(_), do: nil

  defp validate_required_fields(changeset) do
    changeset
    |> validate_format_present()
    |> validate_channels_present()
  end

  defp validate_format_present(changeset) do
    if is_nil(get_field(changeset, :format)) do
      add_error(changeset, :format, "audio format is required")
    else
      changeset
    end
  end

  defp validate_channels_present(changeset) do
    channels = get_field(changeset, :channels)

    cond do
      is_nil(channels) ->
        add_error(changeset, :channels, "audio channels is required")

      channels <= 0 ->
        add_error(changeset, :channels, "audio channels must be positive, got: #{channels}")

      channels > 32 ->
        add_error(changeset, :channels, "audio channels seems unrealistic, got: #{channels}")

      true ->
        changeset
    end
  end

  defp validate_channel_consistency(changeset) do
    # This is the key validation that prevents the "b:a=0k, ac=0" issue
    channels = get_field(changeset, :channels)
    format = get_field(changeset, :format)

    case {channels, format} do
      {nil, _} ->
        # Already handled in validate_channels_present
        changeset

      {0, _} ->
        add_error(changeset, :channels, "audio track cannot have 0 channels")

      {_, nil} ->
        # Already handled in validate_format_present
        changeset

      {_, ""} ->
        add_error(changeset, :format, "audio format cannot be empty")

      {channels, format} when is_integer(channels) and channels > 0 and is_binary(format) ->
        # Valid combination
        changeset

      _ ->
        add_error(
          changeset,
          :base,
          "invalid audio track: channels=#{inspect(channels)}, format=#{inspect(format)}"
        )
    end
  end

  @doc """
  Detects if this audio track represents Atmos content.

  Checks for E-AC-3 format with Atmos in the additional features.
  """
  def atmos?(%__MODULE__{} = track) do
    track.format == "E-AC-3" and
      not is_nil(track.format_additionalfeatures) and
      String.contains?(String.downcase(track.format_additionalfeatures), "atmos")
  end

  @doc """
  Gets the commercial format name if available, falling back to the main format.
  """
  def commercial_format(%__MODULE__{} = track) do
    case track.format_commercial_if_any do
      nil -> track.format
      "" -> track.format
      commercial -> commercial
    end
  end
end
