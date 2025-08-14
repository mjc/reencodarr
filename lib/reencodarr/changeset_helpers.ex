defmodule Reencodarr.ChangesetHelpers do
  @moduledoc """
  Consolidated changeset validation utilities to eliminate duplication.

  Provides reusable validation functions for common patterns across
  all schemas, reducing the duplicated validation logic in MediaInfo
  modules and other Ecto schemas.
  """

  import Ecto.Changeset

  @doc """
  Validates that a required field is present and not nil.

  ## Examples

      iex> changeset |> validate_field_present(:format)
      %Ecto.Changeset{}

      iex> changeset |> validate_field_present(:duration, "duration is required for general track")
      %Ecto.Changeset{}

  """
  def validate_field_present(changeset, field, message \\ nil) do
    if is_nil(get_field(changeset, field)) do
      message = message || "#{field} is required"
      add_error(changeset, field, message)
    else
      changeset
    end
  end

  @doc """
  Validates that a numeric field is positive (greater than zero).

  Handles both integer and float values.

  ## Examples

      iex> changeset |> validate_positive_number(:channels)
      %Ecto.Changeset{}

      iex> changeset |> validate_positive_number(:width, "video width must be positive")
      %Ecto.Changeset{}

  """
  def validate_positive_number(changeset, field, message \\ nil) do
    value = get_field(changeset, field)

    cond do
      is_nil(value) ->
        changeset
      is_number(value) and value <= 0 ->
        message = message || "#{field} must be positive"
        add_error(changeset, field, message)
      true ->
        changeset
    end
  end

  @doc """
  Validates that a numeric field is within reasonable bounds.

  Useful for sanity checking values like channel counts, dimensions, etc.

  ## Examples

      iex> changeset |> validate_reasonable_range(:channels, 1, 32, "unrealistic channel count")
      %Ecto.Changeset{}

  """
  def validate_reasonable_range(changeset, field, min_val, max_val, message \\ nil) do
    value = get_field(changeset, field)

    cond do
      is_nil(value) ->
        changeset
      is_number(value) and (value < min_val or value > max_val) ->
        message = message || "#{field} seems unrealistic, got: #{value}"
        add_error(changeset, field, message)
      true ->
        changeset
    end
  end

  @doc """
  Validates that a field is not empty (for strings) or zero (for numbers).

  ## Examples

      iex> changeset |> validate_not_empty(:format)
      %Ecto.Changeset{}

  """
  def validate_not_empty(changeset, field, message \\ nil) do
    value = get_field(changeset, field)

    cond do
      is_binary(value) and String.trim(value) == "" ->
        message = message || "#{field} cannot be empty"
        add_error(changeset, field, message)
      is_number(value) and value == 0 ->
        message = message || "#{field} cannot be 0"
        add_error(changeset, field, message)
      true ->
        changeset
    end
  end

  @doc """
  Validates resolution fields (width and height) are both present and positive.

  Common pattern for video track validation.
  """
  def validate_resolution_present(changeset) do
    width = get_field(changeset, :width)
    height = get_field(changeset, :height)

    cond do
      is_nil(width) ->
        add_error(changeset, :width, "video width is required")
      is_nil(height) ->
        add_error(changeset, :height, "video height is required")
      width <= 0 ->
        add_error(changeset, :width, "video width must be positive")
      height <= 0 ->
        add_error(changeset, :height, "video height must be positive")
      true ->
        changeset
    end
  end

  @doc """
  Validates audio channel information is reasonable.

  Common pattern for audio track validation.
  """
  def validate_audio_channels(changeset) do
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

  @doc """
  Validates that essential track fields are consistent.

  Prevents tracks from having zero values in critical fields while still having a format.
  """
  def validate_track_consistency(changeset, field_checks \\ []) do
    format = get_field(changeset, :format)

    if format && String.trim(format) != "" do
      Enum.reduce(field_checks, changeset, fn {field, zero_message}, acc ->
        value = get_field(acc, field)
        if value == 0 do
          add_error(acc, field, zero_message)
        else
          acc
        end
      end)
    else
      changeset
    end
  end
end
