defmodule Reencodarr.Media.MediaInfoMigration do
  @moduledoc """
  Migration utilities for transitioning existing MediaInfo parsing to use
  the enhanced FieldTypes system with proper type conversion and validation.

  This module provides tools to:
  1. Migrate existing convert_field_value logic to FieldTypes
  2. Bridge the gap between legacy and enhanced parsing
  3. Provide backwards compatibility during transition
  """

  alias Reencodarr.Media.{EnhancedMediaInfo, MediaInfo}
  alias Reencodarr.Media.MediaInfo.{AudioTrack, GeneralTrack, TextTrack, VideoTrack}

  @doc """
  Legacy convert_field_value implementation for backwards compatibility.
  This preserves the original behavior for fields not yet covered by FieldTypes.
  """
  def convert_field_value_legacy(field_name, value) when is_binary(value) do
    cond do
      field_name in [
        :FileSize,
        :Duration,
        :OverallBitRate,
        :Width,
        :Height,
        :SamplingRate,
        :BitRate,
        :FrameCount,
        :ElementCount,
        :StreamSize
      ] ->
        parse_numeric_field(value)

      field_name in [:FrameRate] ->
        parse_float_field(value)

      field_name in [:VideoCount, :AudioCount, :TextCount, :Channels] ->
        parse_integer_field(value)

      true ->
        # Keep as string for unknown fields
        {:ok, value}
    end
  end

  def convert_field_value_legacy(_field_name, value) do
    {:ok, value}
  end

  defp parse_numeric_field(value) do
    case parse_numeric_value(value) do
      {:ok, numeric_value} -> {:ok, numeric_value}
      # Keep original if parsing fails
      {:error, _} -> {:ok, value}
    end
  end

  defp parse_float_field(value) do
    case Float.parse(value) do
      {float_val, ""} -> {:ok, float_val}
      # Keep original if parsing fails
      _ -> {:ok, value}
    end
  end

  defp parse_integer_field(value) do
    case Integer.parse(value) do
      {int_val, ""} -> {:ok, int_val}
      # Keep original if parsing fails
      _ -> {:ok, value}
    end
  end

  @doc """
  Migrates a MediaInfo struct parsed with legacy methods to use enhanced
  type conversion and validation.
  """
  @spec migrate_media_info(MediaInfo.t()) :: {:ok, MediaInfo.t()} | {:error, term()}
  def migrate_media_info(%MediaInfo{} = media_info) do
    updated_tracks =
      media_info.media.track
      |> Enum.map(&migrate_track/1)
      |> Enum.map(fn
        {:ok, track} -> track
        {:error, _} -> nil
      end)
      |> Enum.filter(&(&1 != nil))

    updated_media = %{media_info.media | track: updated_tracks}
    updated_media_info = %{media_info | media: updated_media}

    {:ok, updated_media_info}
  rescue
    error -> {:error, error}
  end

  @doc """
  Provides a comparison between legacy and enhanced parsing for debugging
  and validation purposes.
  """
  @spec compare_parsing_methods(map()) :: %{
          legacy: {:ok, MediaInfo.t()} | {:error, term()},
          enhanced_strict: {:ok, MediaInfo.t()} | {:error, term()},
          enhanced_lenient: {:ok, MediaInfo.t()} | {:error, term()},
          differences: list(),
          recommendations: list()
        }
  def compare_parsing_methods(json_data) do
    legacy_result =
      try do
        MediaInfo.from_json(json_data)
        |> case do
          [media_info] -> {:ok, media_info}
          media_infos when is_list(media_infos) -> {:ok, List.first(media_infos)}
          error -> {:error, error}
        end
      rescue
        error -> {:error, error}
      end

    enhanced_strict = EnhancedMediaInfo.parse_json(json_data, :strict)
    enhanced_lenient = EnhancedMediaInfo.parse_json(json_data, :lenient)

    differences = analyze_differences(legacy_result, enhanced_strict, enhanced_lenient)
    recommendations = generate_recommendations(differences)

    %{
      legacy: legacy_result,
      enhanced_strict: enhanced_strict,
      enhanced_lenient: enhanced_lenient,
      differences: differences,
      recommendations: recommendations
    }
  end

  @doc """
  Validates that the migration preserved all essential data while improving
  type safety and consistency.
  """
  @spec validate_migration(MediaInfo.t(), MediaInfo.t()) ::
          {:ok, :valid} | {:error, list()}
  def validate_migration(original, migrated) do
    errors = []

    # Check track counts
    errors =
      if length(original.media.track) != length(migrated.media.track) do
        [
          {:track_count_mismatch, length(original.media.track), length(migrated.media.track)}
          | errors
        ]
      else
        errors
      end

    # Check essential fields are preserved
    track_errors =
      Enum.zip(original.media.track, migrated.media.track)
      |> Enum.with_index()
      |> Enum.flat_map(fn {{orig_track, migr_track}, index} ->
        validate_track_migration(orig_track, migr_track, index)
      end)

    all_errors = errors ++ track_errors

    case all_errors do
      [] -> {:ok, :valid}
      errors -> {:error, errors}
    end
  end

  # Private helper functions

  defp migrate_track(%GeneralTrack{} = track) do
    # Keep as-is for now
    {:ok, track}
  end

  defp migrate_track(%VideoTrack{} = track) do
    # Keep as-is for now
    {:ok, track}
  end

  defp migrate_track(%AudioTrack{} = track) do
    # Keep as-is for now
    {:ok, track}
  end

  defp migrate_track(%TextTrack{} = track) do
    # Keep as-is for now
    {:ok, track}
  end

  defp migrate_track(track) do
    # Unknown track type, keep as-is
    {:ok, track}
  end

  defp parse_numeric_value(value) do
    if String.contains?(value, ".") do
      case Float.parse(value) do
        {float_val, ""} -> {:ok, float_val}
        _ -> {:error, :invalid_float}
      end
    else
      case Integer.parse(value) do
        {int_val, ""} -> {:ok, int_val}
        _ -> {:error, :invalid_integer}
      end
    end
  end

  defp analyze_differences(legacy_result, enhanced_strict, _enhanced_lenient) do
    differences = []

    # Compare success/failure
    differences =
      case {legacy_result, enhanced_strict} do
        {{:ok, _}, {:error, _}} ->
          [{:parsing_difference, :legacy_succeeds_strict_fails} | differences]

        {{:error, _}, {:ok, _}} ->
          [{:parsing_difference, :legacy_fails_strict_succeeds} | differences]

        _ ->
          differences
      end

    # Compare field types if both succeeded
    case {legacy_result, enhanced_strict} do
      {{:ok, legacy_info}, {:ok, enhanced_info}} ->
        differences ++ compare_field_types(legacy_info, enhanced_info)

      _ ->
        differences
    end
  end

  defp compare_field_types(legacy_info, enhanced_info) do
    # Compare track types and field values
    legacy_tracks = legacy_info.media.track
    enhanced_tracks = enhanced_info.media.track

    Enum.zip(legacy_tracks, enhanced_tracks)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{legacy_track, enhanced_track}, index} ->
      compare_track_fields(legacy_track, enhanced_track, index)
    end)
  end

  defp compare_track_fields(legacy_track, enhanced_track, track_index) do
    legacy_map = Map.from_struct(legacy_track)
    enhanced_map = Map.from_struct(enhanced_track)

    Enum.flat_map(legacy_map, fn {field, legacy_value} ->
      enhanced_value = Map.get(enhanced_map, field)

      cond do
        legacy_value == enhanced_value ->
          []

        is_binary(legacy_value) and is_number(enhanced_value) ->
          # This is expected - string to numeric conversion
          [
            {:type_conversion, track_index, field, :string_to_numeric, legacy_value,
             enhanced_value}
          ]

        true ->
          # Unexpected difference
          [{:unexpected_difference, track_index, field, legacy_value, enhanced_value}]
      end
    end)
  end

  defp generate_recommendations(differences) do
    recommendations = []

    # Check for validation failures
    recommendations =
      if Enum.any?(differences, &match?({:parsing_difference, :legacy_succeeds_strict_fails}, &1)) do
        ["Consider using lenient mode for initial migration" | recommendations]
      else
        recommendations
      end

    # Check for type conversions
    type_conversions = Enum.filter(differences, &match?({:type_conversion, _, _, _, _, _}, &1))

    recommendations =
      if length(type_conversions) > 0 do
        [
          "#{length(type_conversions)} fields were converted from string to numeric types"
          | recommendations
        ]
      else
        recommendations
      end

    # Check for unexpected differences
    unexpected = Enum.filter(differences, &match?({:unexpected_difference, _, _, _, _}, &1))

    recommendations =
      if length(unexpected) > 0 do
        [
          "#{length(unexpected)} unexpected differences found - review carefully"
          | recommendations
        ]
      else
        recommendations
      end

    case recommendations do
      [] -> ["Migration looks clean - enhanced parsing should work well"]
      recs -> recs
    end
  end

  defp validate_track_migration(original, migrated, index) do
    _errors = []

    # Check that essential identifying fields are preserved
    essential_fields = [:Format, :"@type"]

    Enum.flat_map(essential_fields, fn field ->
      orig_val = Map.get(original, field)
      migr_val = Map.get(migrated, field)

      if orig_val != migr_val do
        [{:essential_field_changed, index, field, orig_val, migr_val}]
      else
        []
      end
    end)
  end
end
