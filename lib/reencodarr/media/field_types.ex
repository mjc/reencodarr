defmodule Reencodarr.Media.FieldTypes do
  @moduledoc """
  Centralized field type definitions and conversion system for MediaInfo data.

  This module provides a unified approach to:
  - Defining field types and validation rules
  - Converting raw MediaInfo JSON to properly typed values
  - Validating field values according to their semantic rules
  - Generating descriptive error messages for invalid data
  """

  alias Reencodarr.Media.CodecHelper

  @type field_type ::
          :integer
          | :float
          | :string
          | :boolean
          | {:integer, keyword()}
          | {:float, keyword()}
          | {:string, keyword()}
          | {:array, :string}

  @type validation_error :: {atom(), String.t()}
  @type conversion_result :: {:ok, term()} | {:error, validation_error()}

  # Field type definitions for each track type
  @general_track_fields %{
    FileSize: {:integer, min: 0, max: 1_000_000_000_000},
    Duration: {:float, min: 0.0, max: 86400.0},
    OverallBitRate: {:integer, min: 0, max: 1_000_000_000},
    FrameRate: {:float, min: 0.0, max: 120.0},
    FrameCount: {:integer, min: 0},
    VideoCount: {:integer, min: 0, max: 10},
    AudioCount: {:integer, min: 0, max: 50},
    TextCount: {:integer, min: 0, max: 100},
    Title: :string,
    Format: :string,
    Format_Profile: :string,
    Format_Version: :string,
    FileExtension: :string,
    CodecID: :string,
    CodecID_Compatible: :string,
    UniqueID: :string
  }

  @video_track_fields %{
    Width: {:integer, min: 1, max: 8192},
    Height: {:integer, min: 1, max: 8192},
    FrameRate: {:float, min: 0.0, max: 120.0},
    BitRate: {:integer, min: 0, max: 1_000_000_000},
    Duration: {:float, min: 0.0, max: 86400.0},
    Format: :string,
    Format_Profile: :string,
    Format_Level: :string,
    HDR_Format: :string,
    HDR_Format_Compatibility: :string,
    ColorSpace: :string,
    ChromaSubsampling: :string,
    BitDepth: {:integer, min: 1, max: 32},
    Language: :string,
    CodecID: :string,
    StreamOrder: :string,
    ID: :string,
    UniqueID: :string,
    Default: :string,
    Forced: :string,
    Encoded_Library: :string
  }

  @audio_track_fields %{
    Format: :string,
    Format_Commercial_IfAny: :string,
    BitRate: {:integer, min: 0, max: 10_000_000},
    Channels: :string,
    ChannelPositions: :string,
    SamplingRate: {:integer, min: 8000, max: 192_000},
    Duration: {:float, min: 0.0, max: 86400.0},
    Language: :string,
    CodecID: :string,
    StreamOrder: :string,
    ID: :string,
    UniqueID: :string,
    Default: :string,
    Forced: :string
  }

  @text_track_fields %{
    Format: :string,
    Language: :string,
    Title: :string,
    Default: :string,
    Forced: :string,
    Duration: {:float, min: 0.0, max: 86400.0},
    CodecID: :string,
    StreamOrder: :string,
    ID: :string,
    UniqueID: :string,
    BitRate: {:integer, min: 0, max: 10_000_000},
    FrameRate: {:float, min: 0.0, max: 120.0},
    FrameCount: {:integer, min: 0},
    ElementCount: {:integer, min: 0},
    StreamSize: {:integer, min: 0}
  }

  # Video schema fields that need validation (additional to MediaInfo fields)
  @video_schema_fields %{
    # Fields that exist in Video schema but not in MediaInfo tracks
    path: :string,
    size: {:integer, min: 0, max: 1_000_000_000_000},
    video_codecs: {:array, :string},
    audio_codecs: {:array, :string},
    max_audio_channels: {:integer, min: 0, max: 32},
    hdr: :string,
    atmos: :boolean,
    reencoded: :boolean,
    failed: :boolean,
    service_id: :string,
    service_type: :string
  }

  @doc """
  Gets field type definition for a specific track type and field.

  ## Examples

      iex> get_field_type(:general, :FileSize)
      {:integer, min: 0, max: 1_000_000_000_000}

      iex> get_field_type(:video, :Width)
      {:integer, min: 1, max: 8192}
  """
  @spec get_field_type(atom(), atom()) :: field_type() | nil
  def get_field_type(:general, field), do: Map.get(@general_track_fields, field)
  def get_field_type(:video, field), do: Map.get(@video_track_fields, field)
  def get_field_type(:audio, field), do: Map.get(@audio_track_fields, field)
  def get_field_type(:text, field), do: Map.get(@text_track_fields, field)
  def get_field_type(:video_schema, field), do: Map.get(@video_schema_fields, field)
  def get_field_type(_, _), do: nil

  @doc """
  Converts and validates a field value according to its type definition.

  ## Examples

      iex> convert_and_validate(:general, :FileSize, "1024")
      {:ok, 1024}

      iex> convert_and_validate(:video, :Width, "1920")
      {:ok, 1920}

      iex> convert_and_validate(:video, :Width, "0")
      {:error, {:validation_error, "Width must be at least 1, got 0"}}
  """
  @spec convert_and_validate(atom(), atom(), term()) :: conversion_result()
  def convert_and_validate(track_type, field, value) do
    case get_field_type(track_type, field) do
      nil ->
        # Unknown field, return as-is (will go to :extra)
        {:ok, value}

      field_type ->
        convert_value(value, field_type, field)
    end
  end

  @doc """
  Validates a converted value against its type constraints.

  ## Examples

      iex> validate_converted_value(1920, {:integer, min: 1, max: 8192}, :Width)
      :ok

      iex> validate_converted_value(0, {:integer, min: 1, max: 8192}, :Width)
      {:error, {:validation_error, "Width must be at least 1, got 0"}}
  """
  @spec validate_converted_value(term(), field_type(), atom()) ::
          :ok | {:error, validation_error()}
  def validate_converted_value(value, field_type, field_name) do
    case field_type do
      {:integer, constraints} ->
        validate_integer_constraints(value, constraints, field_name)

      {:float, constraints} ->
        validate_float_constraints(value, constraints, field_name)

      {:string, constraints} ->
        validate_string_constraints(value, constraints, field_name)

      _ ->
        :ok
    end
  end

  @doc """
  Gets all field types for a specific track type.

  ## Examples

      iex> get_all_field_types(:video)
      %{Width: {:integer, min: 1, max: 8192}, ...}
  """
  @spec get_all_field_types(atom()) :: map()
  def get_all_field_types(:general), do: @general_track_fields
  def get_all_field_types(:video), do: @video_track_fields
  def get_all_field_types(:audio), do: @audio_track_fields
  def get_all_field_types(:text), do: @text_track_fields
  def get_all_field_types(:video_schema), do: @video_schema_fields
  def get_all_field_types(_), do: %{}

  # Private conversion functions

  defp convert_value(nil, _field_type, _field), do: {:ok, nil}

  defp convert_value(value, :integer, field) do
    case convert_to_integer(value) do
      {:ok, int_value} -> {:ok, int_value}
      {:error, reason} -> {:error, {:conversion_error, "#{field}: #{reason}"}}
    end
  end

  defp convert_value(value, {:integer, constraints}, field) do
    case convert_to_integer(value) do
      {:ok, int_value} ->
        case validate_integer_constraints(int_value, constraints, field) do
          :ok -> {:ok, int_value}
          error -> error
        end

      {:error, reason} ->
        {:error, {:conversion_error, "#{field}: #{reason}"}}
    end
  end

  defp convert_value(value, :float, field) do
    case convert_to_float(value) do
      {:ok, float_value} -> {:ok, float_value}
      {:error, reason} -> {:error, {:conversion_error, "#{field}: #{reason}"}}
    end
  end

  defp convert_value(value, {:float, constraints}, field) do
    case convert_to_float(value) do
      {:ok, float_value} ->
        case validate_float_constraints(float_value, constraints, field) do
          :ok -> {:ok, float_value}
          error -> error
        end

      {:error, reason} ->
        {:error, {:conversion_error, "#{field}: #{reason}"}}
    end
  end

  defp convert_value(value, :string, _field) do
    {:ok, to_string(value)}
  end

  defp convert_value(value, {:string, constraints}, field) do
    string_value = to_string(value)

    case validate_string_constraints(string_value, constraints, field) do
      :ok -> {:ok, string_value}
      error -> error
    end
  end

  defp convert_value(value, :boolean, _field) do
    {:ok, convert_to_boolean(value)}
  end

  defp convert_value(value, {:array, :string}, _field) when is_list(value) do
    {:ok, Enum.map(value, &to_string/1)}
  end

  defp convert_value(value, {:array, :string}, _field) do
    {:ok, [to_string(value)]}
  end

  # Type conversion helpers

  defp convert_to_integer(value) when is_integer(value), do: {:ok, value}

  defp convert_to_integer(value) when is_float(value) do
    {:ok, trunc(value)}
  end

  defp convert_to_integer(value) when is_binary(value) do
    case CodecHelper.parse_int(value, nil) do
      nil -> {:error, "cannot convert '#{value}' to integer"}
      int_value -> {:ok, int_value}
    end
  end

  defp convert_to_integer(value) do
    {:error, "cannot convert #{inspect(value)} to integer"}
  end

  defp convert_to_float(value) when is_float(value), do: {:ok, value}
  defp convert_to_float(value) when is_integer(value), do: {:ok, value / 1.0}

  defp convert_to_float(value) when is_binary(value) do
    case CodecHelper.parse_float(value, nil) do
      nil -> {:error, "cannot convert '#{value}' to float"}
      float_value -> {:ok, float_value}
    end
  end

  defp convert_to_float(value) do
    {:error, "cannot convert #{inspect(value)} to float"}
  end

  defp convert_to_boolean(value) when is_boolean(value), do: value
  defp convert_to_boolean("true"), do: true
  defp convert_to_boolean("false"), do: false
  defp convert_to_boolean("yes"), do: true
  defp convert_to_boolean("no"), do: false
  defp convert_to_boolean("1"), do: true
  defp convert_to_boolean("0"), do: false
  defp convert_to_boolean(1), do: true
  defp convert_to_boolean(0), do: false
  defp convert_to_boolean(_), do: false

  # Validation constraint helpers

  defp validate_integer_constraints(value, constraints, field_name) do
    Enum.reduce_while(constraints, :ok, fn {constraint, constraint_value}, _acc ->
      case validate_integer_constraint(value, constraint, constraint_value, field_name) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_integer_constraint(value, :min, min_value, field_name) do
    if value >= min_value do
      :ok
    else
      {:error, {:validation_error, "#{field_name} must be at least #{min_value}, got #{value}"}}
    end
  end

  defp validate_integer_constraint(value, :max, max_value, field_name) do
    if value <= max_value do
      :ok
    else
      {:error, {:validation_error, "#{field_name} must be at most #{max_value}, got #{value}"}}
    end
  end

  defp validate_float_constraints(value, constraints, field_name) do
    Enum.reduce_while(constraints, :ok, fn {constraint, constraint_value}, _acc ->
      case validate_float_constraint(value, constraint, constraint_value, field_name) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_float_constraint(value, :min, min_value, field_name) do
    if value >= min_value do
      :ok
    else
      {:error, {:validation_error, "#{field_name} must be at least #{min_value}, got #{value}"}}
    end
  end

  defp validate_float_constraint(value, :max, max_value, field_name) do
    if value <= max_value do
      :ok
    else
      {:error, {:validation_error, "#{field_name} must be at most #{max_value}, got #{value}"}}
    end
  end

  defp validate_string_constraints(value, constraints, field_name) do
    Enum.reduce_while(constraints, :ok, fn {constraint, constraint_value}, _acc ->
      case validate_string_constraint(value, constraint, constraint_value, field_name) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_string_constraint(value, :min_length, min_length, field_name) do
    if String.length(value) >= min_length do
      :ok
    else
      {:error,
       {:validation_error,
        "#{field_name} must be at least #{min_length} characters, got #{String.length(value)}"}}
    end
  end

  defp validate_string_constraint(value, :max_length, max_length, field_name) do
    if String.length(value) <= max_length do
      :ok
    else
      {:error,
       {:validation_error,
        "#{field_name} must be at most #{max_length} characters, got #{String.length(value)}"}}
    end
  end
end
