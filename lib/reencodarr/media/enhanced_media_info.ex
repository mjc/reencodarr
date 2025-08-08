defmodule Reencodarr.Media.EnhancedMediaInfo do
  @moduledoc """
  Enhanced MediaInfo parsing using the FieldTypes validation system.

  This module provides the next generation of MediaInfo parsing that:
  1. Uses FieldTypes for type conversion and validation
  2. Provides better error reporting
  3. Handles type inconsistencies gracefully
  4. Supports both strict and lenient parsing modes
  """

  alias Reencodarr.Media.{FieldTypes, ValidationPipeline}
  alias Reencodarr.Media.MediaInfo
  alias Reencodarr.Media.MediaInfo.{AudioTrack, GeneralTrack, TextTrack, VideoTrack}

  @type parsing_mode :: :strict | :lenient
  @type parsing_result :: {:ok, MediaInfo.t()} | {:error, [validation_error()]}
  @type validation_error ::
          {:parsing_error, String.t()}
          | {:field_error, atom(), String.t()}
          | {:track_error, atom(), String.t()}

  @doc """
  Enhanced JSON parsing with FieldTypes validation.

  ## Modes
  - `:strict` - Fails on any validation error
  - `:lenient` - Logs validation errors but continues parsing

  ## Examples

      iex> parse_json(json_data, :strict)
      {:ok, %MediaInfo{...}}

      iex> parse_json(invalid_json, :strict)
      {:error, [{:field_error, :Width, "Width must be at least 1, got 0"}]}
  """
  @spec parse_json(map() | list() | nil, parsing_mode()) :: parsing_result()
  def parse_json(json_data, mode \\ :lenient)

  def parse_json(nil, _mode), do: {:ok, %MediaInfo{creatingLibrary: nil, media: nil}}

  def parse_json(json_data, mode) when is_list(json_data) do
    case parse_media_list(json_data, mode) do
      {:ok, media_infos} -> {:ok, List.first(media_infos)}
      error -> error
    end
  end

  def parse_json(json_data, mode) when is_map(json_data) do
    parse_single_media_info(json_data, mode)
  end

  @doc """
  Converts a MediaInfo struct to Video schema parameters with validation.

  This function extracts and validates all the parameters needed for a Video changeset,
  ensuring type consistency and proper validation.
  """
  @spec to_video_params(MediaInfo.t()) :: {:ok, map()} | {:error, [validation_error()]}
  def to_video_params(%MediaInfo{media: %{track: tracks}}) when is_list(tracks) do
    params = extract_video_parameters(tracks)

    # Validate using both track-specific and video schema validations
    case ValidationPipeline.validate_video_params(params) do
      {:ok, validated_params} -> {:ok, validated_params}
      {:error, errors} -> {:error, errors}
    end
  end

  def to_video_params(_), do: {:error, [{:parsing_error, "invalid MediaInfo structure"}]}

  @doc """
  Validates and converts MediaInfo tracks using FieldTypes system.

  This provides enhanced track validation that can identify and fix
  common type inconsistencies found in MediaInfo JSON data.
  """
  @spec validate_tracks([struct()], parsing_mode()) ::
          {:ok, [struct()]} | {:error, [validation_error()]}
  def validate_tracks(tracks, mode \\ :lenient) do
    {validated_tracks, errors} =
      Enum.reduce(tracks, {[], []}, fn track, {valid_acc, error_acc} ->
        process_track_validation(track, mode, {valid_acc, error_acc})
      end)

    build_validation_result(validated_tracks, errors, mode)
  end

  defp process_track_validation(track, mode, {valid_acc, error_acc}) do
    case ValidationPipeline.validate_track(track) do
      {:ok, validated_track} ->
        {[validated_track | valid_acc], error_acc}

      {:error, track_errors} ->
        handle_track_validation_error(track, track_errors, mode, {valid_acc, error_acc})
    end
  end

  defp handle_track_validation_error(track, track_errors, mode, {valid_acc, error_acc}) do
    case mode do
      :strict ->
        {valid_acc, track_errors ++ error_acc}

      :lenient ->
        # Log errors but keep original track
        log_validation_errors(track_errors)
        {[track | valid_acc], error_acc}
    end
  end

  defp build_validation_result(validated_tracks, errors, mode) do
    case {mode, errors} do
      {:strict, []} -> {:ok, Enum.reverse(validated_tracks)}
      {:strict, errors} -> {:error, Enum.reverse(errors)}
      {:lenient, _} -> {:ok, Enum.reverse(validated_tracks)}
    end
  end

  @doc """
  Enhanced conversion report showing what was fixed/validated.

  This provides detailed information about the parsing and validation
  process for debugging and monitoring purposes.
  """
  @spec conversion_report(map(), parsing_mode()) :: %{
          mode: parsing_mode(),
          tracks_processed: integer(),
          fields_converted: integer(),
          validation_errors: [validation_error()],
          warnings: [String.t()],
          fixes_applied: [String.t()]
        }
  def conversion_report(json_data, mode \\ :lenient) do
    start_time = System.monotonic_time(:millisecond)

    result = parse_json(json_data, mode)

    end_time = System.monotonic_time(:millisecond)
    processing_time = end_time - start_time

    case result do
      {:ok, media_info} ->
        %{
          mode: mode,
          processing_time_ms: processing_time,
          tracks_processed: count_tracks(media_info),
          fields_converted: count_converted_fields(media_info),
          validation_errors: [],
          warnings: [],
          fixes_applied: [],
          status: :success
        }

      {:error, errors} ->
        %{
          mode: mode,
          processing_time_ms: processing_time,
          tracks_processed: 0,
          fields_converted: 0,
          validation_errors: errors,
          warnings: generate_warnings(errors),
          fixes_applied: [],
          status: :error
        }
    end
  end

  # Private functions

  defp parse_media_list(json_list, mode) do
    results = Enum.map(json_list, &parse_single_media_info(&1, mode))

    errors =
      Enum.flat_map(results, fn
        {:error, errs} -> errs
        _ -> []
      end)

    case {mode, errors} do
      {:strict, []} ->
        media_infos = Enum.map(results, fn {:ok, mi} -> mi end)
        {:ok, media_infos}

      {:strict, errors} ->
        {:error, errors}

      {:lenient, _} ->
        media_infos =
          Enum.map(results, fn
            {:ok, mi} -> mi
            {:error, _} -> %MediaInfo{creatingLibrary: nil, media: nil}
          end)

        {:ok, media_infos}
    end
  end

  defp parse_single_media_info(json_data, mode) do
    # Parse basic structure first
    creating_library = parse_creating_library(Map.get(json_data, "creatingLibrary"))
    media_data = Map.get(json_data, "media", %{})
    tracks_data = Map.get(media_data, "track", [])

    # Parse and validate tracks using FieldTypes
    case parse_tracks_with_validation(tracks_data, mode) do
      {:ok, validated_tracks} ->
        media = %MediaInfo.Media{
          "@ref": Map.get(media_data, "@ref"),
          track: validated_tracks
        }

        media_info = %MediaInfo{
          creatingLibrary: creating_library,
          media: media
        }

        {:ok, media_info}

      {:error, errors} ->
        {:error, errors}
    end
  rescue
    error ->
      {:error, [{:parsing_error, "Failed to parse MediaInfo: #{inspect(error)}"}]}
  end

  defp parse_creating_library(nil), do: nil

  defp parse_creating_library(data) when is_map(data) do
    %MediaInfo.CreatingLibrary{
      name: Map.get(data, "name"),
      version: Map.get(data, "version"),
      url: Map.get(data, "url")
    }
  end

  defp parse_tracks_with_validation(tracks_data, mode) do
    {validated_tracks, errors} =
      Enum.reduce(tracks_data, {[], []}, fn track_data, {tracks_acc, errors_acc} ->
        case parse_single_track_with_validation(track_data, mode) do
          {:ok, track} -> {[track | tracks_acc], errors_acc}
          {:error, track_errors} -> {tracks_acc, track_errors ++ errors_acc}
        end
      end)

    case {mode, errors} do
      {:strict, []} -> {:ok, Enum.reverse(validated_tracks)}
      {:strict, errors} -> {:error, Enum.reverse(errors)}
      {:lenient, _} -> {:ok, Enum.reverse(validated_tracks)}
    end
  end

  defp parse_single_track_with_validation(track_data, mode) do
    track_type_str = Map.get(track_data, "@type", "")

    {struct_module, track_type} =
      case String.downcase(track_type_str) do
        "general" -> {GeneralTrack, :general}
        "video" -> {VideoTrack, :video}
        "audio" -> {AudioTrack, :audio}
        "text" -> {TextTrack, :text}
        _ -> {MediaInfo.Track, :unknown}
      end

    if track_type == :unknown do
      # Handle unknown track types
      track = struct(MediaInfo.Track, track_data)
      {:ok, track}
    else
      # Parse with FieldTypes validation
      case parse_track_with_field_types(track_data, struct_module, track_type, mode) do
        {:ok, track} -> {:ok, track}
        {:error, errors} -> {:error, errors}
      end
    end
  end

  defp parse_track_with_field_types(track_data, struct_module, track_type, mode) do
    known_fields = get_known_fields(struct_module)

    {converted_fields, extra_fields, errors} =
      Enum.reduce(track_data, {%{}, %{}, []}, fn {key, value}, acc ->
        process_field(key, value, known_fields, track_type, mode, acc)
      end)

    build_track_result(converted_fields, extra_fields, errors, struct_module, mode)
  end

  defp process_field(
         key,
         value,
         known_fields,
         track_type,
         mode,
         {fields_acc, extra_acc, errors_acc}
       ) do
    atom_key = atomize_key(key)

    if atom_key in known_fields do
      process_known_field(atom_key, value, track_type, mode, {fields_acc, extra_acc, errors_acc})
    else
      {fields_acc, Map.put(extra_acc, key, value), errors_acc}
    end
  end

  defp process_known_field(atom_key, value, track_type, mode, {fields_acc, extra_acc, errors_acc}) do
    case FieldTypes.convert_and_validate(track_type, atom_key, value) do
      {:ok, converted_value} ->
        {Map.put(fields_acc, atom_key, converted_value), extra_acc, errors_acc}

      {:error, {error_type, message}} ->
        error = {error_type, atom_key, message}
        handle_field_error(error, atom_key, value, mode, {fields_acc, extra_acc, errors_acc})
    end
  end

  defp handle_field_error(error, atom_key, value, mode, {fields_acc, extra_acc, errors_acc}) do
    case mode do
      :strict ->
        {fields_acc, extra_acc, [error | errors_acc]}

      :lenient ->
        # Keep original value in lenient mode
        {Map.put(fields_acc, atom_key, value), extra_acc, errors_acc}
    end
  end

  defp build_track_result(converted_fields, extra_fields, errors, struct_module, mode) do
    case {mode, errors} do
      {:strict, []} ->
        final_fields = maybe_add_extra_fields(converted_fields, extra_fields)
        track = struct(struct_module, final_fields)
        {:ok, track}

      {:strict, errors} ->
        {:error, Enum.reverse(errors)}

      {:lenient, _} ->
        final_fields = maybe_add_extra_fields(converted_fields, extra_fields)
        track = struct(struct_module, final_fields)
        {:ok, track}
    end
  end

  defp maybe_add_extra_fields(converted_fields, extra_fields) do
    if map_size(extra_fields) > 0 do
      Map.put(converted_fields, :extra, extra_fields)
    else
      converted_fields
    end
  end

  defp extract_video_parameters(tracks) do
    # Extract parameters from tracks for Video schema
    general_track = Enum.find(tracks, &match?(%GeneralTrack{}, &1))
    video_tracks = Enum.filter(tracks, &match?(%VideoTrack{}, &1))
    audio_tracks = Enum.filter(tracks, &match?(%AudioTrack{}, &1))
    _text_tracks = Enum.filter(tracks, &match?(%TextTrack{}, &1))

    params = %{}

    # Extract from general track
    params =
      if general_track do
        params
        |> Map.put("duration", Map.get(general_track, :Duration))
        |> Map.put("size", Map.get(general_track, :FileSize))
        |> Map.put("bitrate", Map.get(general_track, :OverallBitRate))
        |> Map.put("video_count", Map.get(general_track, :VideoCount))
        |> Map.put("audio_count", Map.get(general_track, :AudioCount))
        |> Map.put("text_count", Map.get(general_track, :TextCount))
        |> Map.put("title", Map.get(general_track, :Title))
      else
        params
      end

    # Extract from first video track
    params =
      case List.first(video_tracks) do
        nil ->
          params

        video_track ->
          params
          |> Map.put("width", Map.get(video_track, :Width))
          |> Map.put("height", Map.get(video_track, :Height))
          |> Map.put("frame_rate", Map.get(video_track, :FrameRate))
          |> Map.put("hdr", Map.get(video_track, :HDR_Format))
      end

    # Extract codec information
    video_codecs = Enum.map(video_tracks, &Map.get(&1, :Format)) |> Enum.filter(&(&1 != nil))
    audio_codecs = Enum.map(audio_tracks, &Map.get(&1, :Format)) |> Enum.filter(&(&1 != nil))

    params =
      params
      |> Map.put("video_codecs", video_codecs)
      |> Map.put("audio_codecs", audio_codecs)

    # Calculate max audio channels
    max_channels =
      audio_tracks
      |> Enum.map(&parse_channel_count/1)
      |> Enum.max(fn -> 0 end)

    params = Map.put(params, "max_audio_channels", max_channels)

    # Detect Atmos
    atmos =
      Enum.any?(audio_tracks, fn track ->
        format = Map.get(track, :Format) || ""
        String.contains?(String.downcase(format), "atmos")
      end)

    params = Map.put(params, "atmos", atmos)

    params
  end

  defp parse_channel_count(audio_track) do
    channels = Map.get(audio_track, :Channels)

    case channels do
      channels when is_binary(channels) ->
        case Integer.parse(channels) do
          {count, _} -> count
          :error -> 0
        end

      channels when is_integer(channels) ->
        channels

      _ ->
        0
    end
  end

  defp get_known_fields(struct_module) do
    struct_module.__struct__()
    |> Map.keys()
    |> MapSet.new()
    |> MapSet.delete(:__struct__)
    |> MapSet.to_list()
  end

  defp atomize_key(key) when is_binary(key), do: String.to_atom(key)
  defp atomize_key(key) when is_atom(key), do: key

  defp count_tracks(%MediaInfo{media: %{track: tracks}}) when is_list(tracks), do: length(tracks)
  defp count_tracks(_), do: 0

  defp count_converted_fields(%MediaInfo{media: %{track: tracks}}) when is_list(tracks) do
    Enum.reduce(tracks, 0, fn track, acc ->
      field_count = track |> Map.from_struct() |> Map.keys() |> length()
      acc + field_count
    end)
  end

  defp count_converted_fields(_), do: 0

  defp generate_warnings(errors) do
    Enum.map(errors, fn
      {:field_error, field, message} -> "Field #{field}: #{message}"
      {:track_error, track_type, message} -> "Track #{track_type}: #{message}"
      {:parsing_error, message} -> "Parsing: #{message}"
      _ -> "Unknown error"
    end)
  end

  defp log_validation_errors(errors) do
    Enum.each(errors, fn error ->
      case error do
        {:field_error, field, message} ->
          require Logger
          Logger.warning("Field validation error: #{field} - #{message}")

        {:validation_error, field, message} ->
          require Logger
          Logger.warning("Validation error: #{field} - #{message}")

        _ ->
          require Logger
          Logger.warning("Validation error: #{inspect(error)}")
      end
    end)
  end
end
