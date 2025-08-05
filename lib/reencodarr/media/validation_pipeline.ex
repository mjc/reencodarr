defmodule Reencodarr.Media.ValidationPipeline do
  @moduledoc """
  Validation pipeline for MediaInfo track processing and Video field validation.

  This module provides a comprehensive validation system that:
  - Validates MediaInfo tracks using both Track Protocol and Field Types
  - Converts and validates fields according to their semantic meaning
  - Provides detailed error reporting for invalid data
  - Integrates with the Video changeset validation system
  """

  alias Reencodarr.Media.{FieldTypes, TrackProtocol}
  alias Reencodarr.Media.MediaInfo.{GeneralTrack, VideoTrack, AudioTrack, TextTrack}

  @type validation_result :: {:ok, map()} | {:error, [validation_error()]}
  @type validation_error ::
          {:field_error, atom(), String.t()}
          | {:track_error, atom(), String.t()}
          | {:conversion_error, atom(), String.t()}

  @doc """
  Validates a complete MediaInfo struct with all its tracks.

  Returns validated data or a list of validation errors.

  ## Examples

      iex> validate_media_info(media_info)
      {:ok, %{general: general_track, video: [video_track], audio: [audio_track]}}

      iex> validate_media_info(invalid_media_info)
      {:error, [
        {:field_error, :Width, "Width must be at least 1, got 0"},
        {:track_error, :video, "video track is invalid"}
      ]}
  """
  @spec validate_media_info(struct()) :: validation_result()
  def validate_media_info(%{media: %{track: tracks}}) when is_list(tracks) do
    case validate_all_tracks(tracks) do
      {:ok, validated_tracks} ->
        case validate_track_relationships(validated_tracks) do
          :ok -> {:ok, validated_tracks}
          {:error, errors} -> {:error, errors}
        end

      {:error, errors} ->
        {:error, errors}
    end
  end

  def validate_media_info(_) do
    {:error, [{:track_error, :general, "invalid MediaInfo structure"}]}
  end

  @doc """
  Validates a single track using both Protocol validation and Field Type validation.

  ## Examples

      iex> validate_track(%VideoTrack{Width: 1920, Height: 1080})
      {:ok, %VideoTrack{Width: 1920, Height: 1080}}

      iex> validate_track(%VideoTrack{Width: 0, Height: 1080})
      {:error, [{:field_error, :Width, "Width must be at least 1, got 0"}]}
  """
  @spec validate_track(struct()) :: {:ok, struct()} | {:error, [validation_error()]}
  def validate_track(track) do
    track_type = get_track_type_from_struct(track)

    with :ok <- validate_track_protocol(track, track_type),
         {:ok, validated_fields} <- validate_track_fields(track, track_type) do
      {:ok, struct(track.__struct__, validated_fields)}
    else
      {:error, errors} when is_list(errors) -> {:error, errors}
      {:error, error} -> {:error, [error]}
    end
  end

  @doc """
  Validates video parameters extracted from MediaInfo for Video changeset.

  This function is specifically designed to work with the Video schema
  and provides validation for the parameters that will be cast into a Video changeset.

  ## Examples

      iex> validate_video_params(%{"width" => "1920", "height" => "1080", ...})
      {:ok, %{width: 1920, height: 1080, ...}}

      iex> validate_video_params(%{"width" => "0", "height" => "1080"})
      {:error, [{:field_error, :width, "width must be positive"}]}
  """
  @spec validate_video_params(map()) :: validation_result()
  def validate_video_params(params) when is_map(params) do
    # Define Video schema field validations
    video_validations = %{
      "width" => &validate_video_width/1,
      "height" => &validate_video_height/1,
      "duration" => &validate_duration/1,
      "frame_rate" => &validate_frame_rate/1,
      "bitrate" => &validate_bitrate/1,
      "size" => &validate_file_size/1,
      "video_count" => &validate_count/1,
      "audio_count" => &validate_count/1,
      "text_count" => &validate_count/1,
      "max_audio_channels" => &validate_audio_channels/1,
      "video_codecs" => &validate_codec_list/1,
      "audio_codecs" => &validate_codec_list/1,
      "title" => &validate_title/1,
      "hdr" => &validate_hdr/1,
      "atmos" => &validate_boolean/1,
      "reencoded" => &validate_boolean/1,
      "failed" => &validate_boolean/1
    }

    errors =
      Enum.reduce(params, [], fn {key, value}, acc ->
        case Map.get(video_validations, key) do
          # Skip unknown fields
          nil ->
            acc

          validator ->
            case validator.(value) do
              :ok -> acc
              {:error, message} -> [{:field_error, String.to_atom(key), message} | acc]
            end
        end
      end)

    case errors do
      [] -> {:ok, params}
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  @doc """
  Provides a comprehensive validation report for debugging purposes.

  ## Examples

      iex> validation_report(media_info)
      %{
        summary: %{total_tracks: 3, valid_tracks: 2, errors: 1},
        track_results: [...],
        field_errors: [...],
        recommendations: [...]
      }
  """
  @spec validation_report(struct()) :: map()
  def validation_report(media_info) do
    case validate_media_info(media_info) do
      {:ok, validated_tracks} ->
        %{
          summary: %{
            total_tracks: count_tracks(validated_tracks),
            valid_tracks: count_tracks(validated_tracks),
            errors: 0
          },
          track_results: build_success_report(validated_tracks),
          field_errors: [],
          recommendations: []
        }

      {:error, errors} ->
        %{
          summary: %{
            total_tracks: count_total_tracks(media_info),
            valid_tracks: count_total_tracks(media_info) - length(errors),
            errors: length(errors)
          },
          track_results: [],
          field_errors: errors,
          recommendations: generate_recommendations(errors)
        }
    end
  end

  # Private functions

  defp validate_all_tracks(tracks) do
    {validated_tracks, errors} =
      Enum.reduce(tracks, {[], []}, fn track, {valid_acc, error_acc} ->
        case validate_track(track) do
          {:ok, validated_track} ->
            {[validated_track | valid_acc], error_acc}

          {:error, track_errors} ->
            {valid_acc, track_errors ++ error_acc}
        end
      end)

    case errors do
      [] ->
        grouped_tracks = group_tracks_by_type(Enum.reverse(validated_tracks))
        {:ok, grouped_tracks}

      errors ->
        {:error, Enum.reverse(errors)}
    end
  end

  defp validate_track_protocol(track, track_type) do
    if TrackProtocol.valid?(track) do
      :ok
    else
      {:error, {:track_error, track_type, "#{track_type} track failed protocol validation"}}
    end
  end

  defp validate_track_fields(track, track_type) do
    field_map = Map.from_struct(track)

    validated_fields =
      Enum.reduce(field_map, %{}, fn {field, value}, acc ->
        case FieldTypes.convert_and_validate(track_type, field, value) do
          {:ok, validated_value} ->
            Map.put(acc, field, validated_value)

          {:error, {error_type, message}} ->
            # Store the error but continue processing
            error = {error_type, field, message}
            Process.put(:validation_errors, [error | Process.get(:validation_errors, [])])
            # Keep original value
            Map.put(acc, field, value)
        end
      end)

    case Process.get(:validation_errors, []) do
      [] ->
        {:ok, validated_fields}

      errors ->
        Process.delete(:validation_errors)
        {:error, Enum.reverse(errors)}
    end
  end

  defp validate_track_relationships(validated_tracks) do
    errors = []

    # Check if we have at least one video track if video_count > 0
    errors = validate_video_count_consistency(validated_tracks, errors)

    # Check if audio_count matches actual audio tracks
    errors = validate_audio_count_consistency(validated_tracks, errors)

    # Check reasonable track limits
    errors = validate_track_limits(validated_tracks, errors)

    case errors do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp validate_video_count_consistency(tracks, errors) do
    general = Map.get(tracks, :general)
    video_tracks = Map.get(tracks, :video, [])

    case general do
      %GeneralTrack{VideoCount: video_count} when is_integer(video_count) and video_count > 0 ->
        if length(video_tracks) == 0 do
          [
            {:track_error, :video, "VideoCount is #{video_count} but no video tracks found"}
            | errors
          ]
        else
          errors
        end

      _ ->
        errors
    end
  end

  defp validate_audio_count_consistency(tracks, errors) do
    general = Map.get(tracks, :general)
    audio_tracks = Map.get(tracks, :audio, [])

    case general do
      %GeneralTrack{AudioCount: audio_count} when is_integer(audio_count) ->
        actual_count = length(audio_tracks)

        if audio_count != actual_count do
          [
            {:track_error, :audio,
             "AudioCount is #{audio_count} but found #{actual_count} audio tracks"}
            | errors
          ]
        else
          errors
        end

      _ ->
        errors
    end
  end

  defp validate_track_limits(tracks, errors) do
    video_tracks = Map.get(tracks, :video, [])
    audio_tracks = Map.get(tracks, :audio, [])
    text_tracks = Map.get(tracks, :text, [])

    errors =
      if length(video_tracks) > 10 do
        [
          {:track_error, :video, "Too many video tracks: #{length(video_tracks)} (max 10)"}
          | errors
        ]
      else
        errors
      end

    errors =
      if length(audio_tracks) > 50 do
        [
          {:track_error, :audio, "Too many audio tracks: #{length(audio_tracks)} (max 50)"}
          | errors
        ]
      else
        errors
      end

    if length(text_tracks) > 100 do
      [{:track_error, :text, "Too many text tracks: #{length(text_tracks)} (max 100)"} | errors]
    else
      errors
    end
  end

  defp group_tracks_by_type(tracks) do
    Enum.group_by(tracks, fn track ->
      case track do
        %GeneralTrack{} -> :general
        %VideoTrack{} -> :video
        %AudioTrack{} -> :audio
        %TextTrack{} -> :text
        _ -> :unknown
      end
    end)
    # General should be single track
    |> Map.update(:general, nil, &List.first/1)
  end

  defp get_track_type_from_struct(%GeneralTrack{}), do: :general
  defp get_track_type_from_struct(%VideoTrack{}), do: :video
  defp get_track_type_from_struct(%AudioTrack{}), do: :audio
  defp get_track_type_from_struct(%TextTrack{}), do: :text
  defp get_track_type_from_struct(_), do: :unknown

  # Video parameter validators

  defp validate_video_width(value) when is_integer(value) and value > 0 and value <= 8192, do: :ok

  defp validate_video_width(value) when is_integer(value) and value <= 0,
    do: {:error, "width must be positive"}

  defp validate_video_width(value) when is_integer(value),
    do: {:error, "width must be at most 8192"}

  defp validate_video_width(_), do: {:error, "width must be an integer"}

  defp validate_video_height(value) when is_integer(value) and value > 0 and value <= 8192,
    do: :ok

  defp validate_video_height(value) when is_integer(value) and value <= 0,
    do: {:error, "height must be positive"}

  defp validate_video_height(value) when is_integer(value),
    do: {:error, "height must be at most 8192"}

  defp validate_video_height(_), do: {:error, "height must be an integer"}

  defp validate_duration(value) when is_float(value) and value >= 0.0 and value <= 86400.0,
    do: :ok

  defp validate_duration(value) when is_float(value) and value < 0.0,
    do: {:error, "duration cannot be negative"}

  defp validate_duration(value) when is_float(value),
    do: {:error, "duration cannot exceed 24 hours"}

  defp validate_duration(_), do: {:error, "duration must be a float"}

  defp validate_frame_rate(value) when is_float(value) and value >= 0.0 and value <= 120.0,
    do: :ok

  defp validate_frame_rate(value) when is_float(value) and value < 0.0,
    do: {:error, "frame rate cannot be negative"}

  defp validate_frame_rate(value) when is_float(value),
    do: {:error, "frame rate cannot exceed 120 fps"}

  defp validate_frame_rate(_), do: {:error, "frame rate must be a float"}

  defp validate_bitrate(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_bitrate(value) when is_integer(value), do: {:error, "bitrate cannot be negative"}
  defp validate_bitrate(_), do: {:error, "bitrate must be an integer"}

  defp validate_file_size(value) when is_integer(value) and value >= 0, do: :ok

  defp validate_file_size(value) when is_integer(value),
    do: {:error, "file size cannot be negative"}

  defp validate_file_size(_), do: {:error, "file size must be an integer"}

  defp validate_count(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_count(value) when is_integer(value), do: {:error, "count cannot be negative"}
  defp validate_count(_), do: {:error, "count must be an integer"}

  defp validate_audio_channels(value) when is_integer(value) and value >= 0 and value < 32,
    do: :ok

  defp validate_audio_channels(value) when is_integer(value) and value < 0,
    do: {:error, "audio channels cannot be negative"}

  defp validate_audio_channels(value) when is_integer(value),
    do: {:error, "audio channels cannot exceed 32"}

  defp validate_audio_channels(_), do: {:error, "audio channels must be an integer"}

  defp validate_codec_list(value) when is_list(value), do: :ok
  defp validate_codec_list(_), do: {:error, "codec list must be an array"}

  defp validate_title(value) when is_binary(value), do: :ok
  defp validate_title(_), do: {:error, "title must be a string"}

  defp validate_hdr(value) when is_binary(value) or is_nil(value), do: :ok
  defp validate_hdr(_), do: {:error, "HDR must be a string or nil"}

  defp validate_boolean(value) when is_boolean(value), do: :ok
  defp validate_boolean(_), do: {:error, "must be a boolean"}

  # Report generation helpers

  defp count_tracks(tracks) when is_map(tracks) do
    video_count = length(Map.get(tracks, :video, []))
    audio_count = length(Map.get(tracks, :audio, []))
    text_count = length(Map.get(tracks, :text, []))
    general_count = if Map.get(tracks, :general), do: 1, else: 0

    video_count + audio_count + text_count + general_count
  end

  defp count_total_tracks(%{media: %{track: tracks}}) when is_list(tracks), do: length(tracks)
  defp count_total_tracks(_), do: 0

  defp build_success_report(tracks) do
    Enum.map(tracks, fn {type, track_data} ->
      case track_data do
        tracks when is_list(tracks) ->
          Enum.map(tracks, &%{type: type, status: :valid, track: &1})

        single_track ->
          %{type: type, status: :valid, track: single_track}
      end
    end)
    |> List.flatten()
  end

  defp generate_recommendations(errors) do
    errors
    |> Enum.map(&generate_error_recommendation/1)
    |> Enum.uniq()
  end

  defp generate_error_recommendation({:field_error, field, message}) do
    cond do
      String.contains?(message, "must be at least") ->
        "Check if #{field} has a valid minimum value"

      String.contains?(message, "must be at most") ->
        "Check if #{field} value is within reasonable limits"

      String.contains?(message, "cannot convert") ->
        "Verify that #{field} contains valid numeric data"

      true ->
        "Review #{field} data format and content"
    end
  end

  defp generate_error_recommendation({:validation_error, field, message}) do
    cond do
      String.contains?(message, "must be at least") ->
        "Check if #{field} has a valid minimum value"

      String.contains?(message, "must be at most") ->
        "Check if #{field} value is within reasonable limits"

      String.contains?(message, "cannot convert") ->
        "Verify that #{field} contains valid numeric data"

      true ->
        "Review #{field} data format and content"
    end
  end

  defp generate_error_recommendation({:track_error, track_type, _message}) do
    "Review #{track_type} track structure and required fields"
  end

  defp generate_error_recommendation({:conversion_error, field, _message}) do
    "Check data format for #{field} - ensure it matches expected type"
  end
end
