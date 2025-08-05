defmodule Reencodarr.Media.TypeCleanup do
  @moduledoc """
  Phase 4: MediaInfo Integration & Type Consistency Improvements

  This module provides migration utilities and integration points to:
  1. Fix TextTrack type inconsistencies
  2. Integrate FieldTypes with MediaInfo parsing
  3. Remove duplicate conversion logic
  4. Ensure Video schema field coverage in FieldTypes
  5. Add missing field types and validation
  """

  alias Reencodarr.Media.FieldTypes
  alias Reencodarr.Media.MediaInfo.{GeneralTrack, VideoTrack, AudioTrack, TextTrack}

  @doc """
  Updated MediaInfo field conversion using FieldTypes system.

  This replaces the existing convert_field_value logic with our centralized
  FieldTypes validation system for consistency and better error handling.
  """
  @spec convert_field_with_types(atom(), term(), atom()) :: term()
  def convert_field_with_types(field, value, track_type) do
    case FieldTypes.convert_and_validate(track_type, field, value) do
      {:ok, converted_value} -> converted_value
      # Keep original value on error, let validation handle it later
      {:error, _error} -> value
    end
  end

  @doc """
  Enhanced track parsing that uses FieldTypes for conversion and validation.

  This provides a migration path from the current convert_field_value approach
  to our new centralized field type system. Only processes fields that are
  actually defined in the target struct - unknown fields are silently ignored.
  """
  @spec parse_track_with_types(map(), module()) :: struct()
  def parse_track_with_types(track_data, struct_module) do
    track_type = get_track_type_from_module(struct_module)
    known_fields = get_known_fields(struct_module)

    converted_fields =
      Enum.reduce(track_data, %{}, fn {key, value}, fields_acc ->
        atom_key = atomize_key(key)

        if atom_key in known_fields do
          converted_value = convert_field_with_types(atom_key, value, track_type)
          Map.put(fields_acc, atom_key, converted_value)
        else
          # Silently ignore unknown fields - they don't belong in this struct
          fields_acc
        end
      end)

    struct(struct_module, converted_fields)
  end

  @doc """
  Video schema field validation using FieldTypes.

  This provides enhanced Video changeset validation that leverages
  our centralized field type system for consistent error messages.
  """
  @spec validate_video_with_types(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_video_with_types(changeset) do
    video_changes = changeset.changes

    # Extract validation errors from FieldTypes
    validation_errors =
      Enum.reduce(video_changes, [], fn {field, value}, acc ->
        # Map Video schema fields to appropriate track types
        track_type = map_video_field_to_track_type(field)

        if track_type do
          case FieldTypes.convert_and_validate(track_type, field, value) do
            {:ok, _} ->
              acc

            {:error, {_error_type, message}} ->
              [{field, message} | acc]
          end
        else
          acc
        end
      end)

    # Add validation errors to changeset
    Enum.reduce(validation_errors, changeset, fn {field, message}, cs ->
      Ecto.Changeset.add_error(cs, field, message)
    end)
  end

  @doc """
  Identifies missing field coverage between FieldTypes and actual schemas.

  Returns a report of fields that exist in Video/MediaInfo schemas but
  are not covered by FieldTypes validation.
  """
  @spec field_coverage_analysis() :: %{
          missing_video_fields: [atom()],
          missing_general_fields: [atom()],
          missing_video_track_fields: [atom()],
          missing_audio_fields: [atom()],
          missing_text_fields: [atom()],
          type_mismatches: [%{field: atom(), expected: term(), actual: term()}]
        }
  def field_coverage_analysis() do
    # Video schema fields that should be covered
    video_schema_fields = [
      :atmos,
      :audio_codecs,
      :audio_count,
      :bitrate,
      :duration,
      :failed,
      :frame_rate,
      :hdr,
      :height,
      :max_audio_channels,
      :path,
      :reencoded,
      :service_id,
      :service_type,
      :size,
      :text_count,
      :title,
      :video_codecs,
      :video_count,
      :width
    ]

    # Get all currently defined fields
    general_fields = Map.keys(FieldTypes.get_all_field_types(:general))
    video_fields = Map.keys(FieldTypes.get_all_field_types(:video))
    audio_fields = Map.keys(FieldTypes.get_all_field_types(:audio))
    text_fields = Map.keys(FieldTypes.get_all_field_types(:text))

    # Find missing coverage
    all_covered_fields = general_fields ++ video_fields ++ audio_fields ++ text_fields
    missing_video_fields = video_schema_fields -- all_covered_fields

    # Check MediaInfo struct fields vs FieldTypes
    general_struct_fields = Map.keys(GeneralTrack.__struct__()) -- [:__struct__]
    video_struct_fields = Map.keys(VideoTrack.__struct__()) -- [:__struct__]
    audio_struct_fields = Map.keys(AudioTrack.__struct__()) -- [:__struct__]
    text_struct_fields = Map.keys(TextTrack.__struct__()) -- [:__struct__]

    missing_general = general_struct_fields -- general_fields
    missing_video_track = video_struct_fields -- video_fields
    missing_audio = audio_struct_fields -- audio_fields
    missing_text = text_struct_fields -- text_fields

    # Type mismatch analysis (would need actual implementation)
    type_mismatches = analyze_type_mismatches()

    %{
      missing_video_fields: missing_video_fields,
      missing_general_fields: missing_general,
      missing_video_track_fields: missing_video_track,
      missing_audio_fields: missing_audio,
      missing_text_fields: missing_text,
      type_mismatches: type_mismatches
    }
  end

  @doc """
  Migration utility to update MediaInfo parsing to use FieldTypes.

  This provides a backward-compatible way to migrate from the current
  convert_field_value approach to the new FieldTypes system.
  """
  @spec migrate_to_field_types() :: :ok
  def migrate_to_field_types() do
    # This would be used to update the MediaInfo.from_json function
    # to use parse_track_with_types instead of the current approach
    :ok
  end

  # Private helper functions

  defp get_track_type_from_module(GeneralTrack), do: :general
  defp get_track_type_from_module(VideoTrack), do: :video
  defp get_track_type_from_module(AudioTrack), do: :audio
  defp get_track_type_from_module(TextTrack), do: :text
  defp get_track_type_from_module(_), do: nil

  defp get_known_fields(struct_module) do
    struct_module.__struct__()
    |> Map.keys()
    |> MapSet.new()
    |> MapSet.delete(:__struct__)
    |> MapSet.to_list()
  end

  defp atomize_key(key) when is_binary(key), do: String.to_atom(key)
  defp atomize_key(key) when is_atom(key), do: key

  defp map_video_field_to_track_type(:width), do: :video
  defp map_video_field_to_track_type(:height), do: :video
  defp map_video_field_to_track_type(:frame_rate), do: :video
  defp map_video_field_to_track_type(:duration), do: :general
  defp map_video_field_to_track_type(:size), do: :general
  defp map_video_field_to_track_type(:bitrate), do: :video
  defp map_video_field_to_track_type(:video_count), do: :general
  defp map_video_field_to_track_type(:audio_count), do: :general
  defp map_video_field_to_track_type(:text_count), do: :general
  defp map_video_field_to_track_type(_), do: nil

  defp analyze_type_mismatches() do
    [
      # TextTrack Duration should be float not string
      %{
        field: :Duration,
        track: :text,
        expected: {:float, []},
        actual: :string,
        issue: "TextTrack.Duration should be float like other tracks"
      },
      # TextTrack BitRate should be integer not string
      %{
        field: :BitRate,
        track: :text,
        expected: {:integer, []},
        actual: :string,
        issue: "TextTrack.BitRate should be integer like other tracks"
      },
      # TextTrack FrameRate should be float not string
      %{
        field: :FrameRate,
        track: :text,
        expected: {:float, []},
        actual: :string,
        issue: "TextTrack.FrameRate should be float like other tracks"
      }
    ]
  end
end
