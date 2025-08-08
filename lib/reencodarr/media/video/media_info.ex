defmodule Reencodarr.Media.Video.MediaInfo do
  @moduledoc """
  Embedded schema for MediaInfo data with comprehensive validation.

  This module provides structured parsing and validation of MediaInfo JSON output,
  replacing the manual parsing approach in the main MediaInfo module with proper
  Ecto schemas and automatic type conversion.
  """

  use Ecto.Schema
  import Ecto.Changeset
  alias Reencodarr.Media.Video.MediaInfo.{AudioTrack, GeneralTrack, VideoTrack}

  @primary_key false
  embedded_schema do
    embeds_one :general, GeneralTrack
    embeds_many :video_tracks, VideoTrack
    embeds_many :audio_tracks, AudioTrack
  end

  @doc """
  Creates a MediaInfo struct from parsed MediaInfo JSON data.

  ## Examples
      iex> MediaInfo.from_json(mediainfo_data)
      {:ok, %MediaInfo{...}}

      iex> MediaInfo.from_json(invalid_data)
      {:error, %Ecto.Changeset{...}}
  """
  def from_json(json_data) do
    case extract_tracks_from_json(json_data) do
      {:ok, tracks} ->
        # Build the embedded schema
        attrs = %{
          "general" => find_track_by_type(tracks, "General"),
          "video_tracks" => find_tracks_by_type(tracks, "Video"),
          "audio_tracks" => find_tracks_by_type(tracks, "Audio"),
          "text_tracks" => find_tracks_by_type(tracks, "Text")
        }

        changeset = changeset(%__MODULE__{}, attrs)

        if changeset.valid? do
          applied_schema = Ecto.Changeset.apply_changes(changeset)
          {:ok, applied_schema}
        else
          # Better error reporting for debugging
          error_details = %{
            errors: changeset.errors,
            valid?: changeset.valid?,
            changes: Map.keys(changeset.changes),
            action: changeset.action
          }

          {:error, "MediaInfo validation failed: #{inspect(error_details)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      {:error, "Exception parsing MediaInfo: #{Exception.message(e)}"}
  end

  @doc """
  Extracts video parameters suitable for the Video schema.

  This replaces the complex manual extraction in the main MediaInfo module.
  """
  def to_video_params(%__MODULE__{} = media_info) do
    with {:ok, basic_params} <- extract_basic_params(media_info),
         {:ok, video_params} <- extract_video_params(media_info),
         {:ok, audio_params} <- extract_audio_params(media_info) do
      combined_params =
        basic_params
        |> Map.merge(video_params)
        |> Map.merge(audio_params)

      validate_extracted_params(combined_params)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Private functions for parameter extraction
  defp extract_basic_params(%{general: nil}), do: {:error, "Missing general track"}

  defp extract_basic_params(%{general: general}) do
    params = %{
      "duration" => general.duration || 0.0,
      "size" => general.file_size || 0,
      "bitrate" => general.overall_bit_rate || 0
    }

    {:ok, params}
  end

  defp extract_video_params(%{video_tracks: []}), do: {:error, "No video tracks found"}

  defp extract_video_params(%{video_tracks: video_tracks}) do
    # Use the first video track (primary video stream)
    primary_video = List.first(video_tracks)

    params = %{
      "video_codecs" => extract_video_codecs(video_tracks),
      "width" => primary_video.width,
      "height" => primary_video.height,
      "frame_rate" => primary_video.frame_rate,
      "hdr" => detect_hdr(video_tracks)
    }

    {:ok, params}
  end

  defp extract_audio_params(%{audio_tracks: audio_tracks}) do
    params = %{
      "audio_codecs" => extract_audio_codecs(audio_tracks),
      "max_audio_channels" => calculate_max_audio_channels(audio_tracks),
      "atmos" => detect_atmos(audio_tracks)
    }

    case validate_audio_consistency(params) do
      {:ok, _} -> {:ok, params}
      {:error, reason} -> {:error, "Audio validation failed: #{reason}"}
    end
  end

  defp extract_video_codecs(video_tracks) do
    video_tracks
    |> Enum.map(& &1.format)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp extract_audio_codecs(audio_tracks) do
    audio_tracks
    |> Enum.map(& &1.format)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp calculate_max_audio_channels(audio_tracks) do
    audio_tracks
    |> Enum.map(& &1.channels)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(&>=/2, fn -> 0 end)
  end

  defp detect_hdr(video_tracks) do
    has_hdr =
      Enum.any?(video_tracks, fn track ->
        track.color_space == "BT.2020" or
          not is_nil(track.hdr_format) or
          (not is_nil(track.transfer_characteristics) and
             String.contains?(String.downcase(track.transfer_characteristics), "hlg"))
      end)

    # Return string to match Video schema type
    if has_hdr, do: "HDR", else: nil
  end

  defp detect_atmos(audio_tracks) do
    Enum.any?(audio_tracks, fn track ->
      track.format == "E-AC-3" and
        not is_nil(track.format_additionalfeatures) and
        String.contains?(String.downcase(track.format_additionalfeatures), "atmos")
    end)
  end

  defp validate_audio_consistency(params) do
    audio_codecs = Map.get(params, "audio_codecs", [])
    max_channels = Map.get(params, "max_audio_channels", 0)

    cond do
      is_nil(audio_codecs) or Enum.empty?(audio_codecs) ->
        {:error, "No audio codecs found"}

      is_nil(max_channels) or max_channels == 0 ->
        {:error, "Invalid audio channels: #{inspect(max_channels)}"}

      true ->
        {:ok, params}
    end
  end

  defp validate_extracted_params(params) do
    required_fields = ["duration", "video_codecs", "audio_codecs", "max_audio_channels"]

    missing_fields =
      required_fields
      |> Enum.filter(fn field ->
        value = Map.get(params, field)
        is_nil(value) or (is_list(value) and Enum.empty?(value))
      end)

    case missing_fields do
      [] -> {:ok, params}
      fields -> {:error, "Missing required fields: #{Enum.join(fields, ", ")}"}
    end
  end

  # Changeset for validation
  def changeset(media_info, attrs) do
    media_info
    |> cast(attrs, [])
    |> cast_embed(:general, required: true)
    |> cast_embed(:video_tracks, required: true)
    |> cast_embed(:audio_tracks, required: false)
    |> validate_track_consistency()
  end

  defp validate_track_consistency(changeset) do
    changeset
    |> validate_video_tracks_present()
    |> validate_audio_track_consistency()
  end

  defp validate_video_tracks_present(changeset) do
    video_tracks = get_field(changeset, :video_tracks) || []

    if Enum.empty?(video_tracks) do
      add_error(changeset, :video_tracks, "at least one video track is required")
    else
      changeset
    end
  end

  defp validate_audio_track_consistency(changeset) do
    audio_tracks = get_field(changeset, :audio_tracks) || []

    # Validate that if we have audio tracks, they have valid channel information
    invalid_audio_tracks =
      Enum.filter(audio_tracks, fn track ->
        is_nil(track.channels) or track.channels == 0
      end)

    if length(invalid_audio_tracks) > 0 do
      add_error(changeset, :audio_tracks, "audio tracks must have valid channel information")
    else
      changeset
    end
  end

  # Helper functions for track extraction and parsing

  defp extract_tracks_from_json(%{"media" => %{"track" => tracks}}) when is_list(tracks) do
    {:ok, tracks}
  end

  defp extract_tracks_from_json(%{"media" => media}) when is_map(media) do
    # Handle flat structure - convert to track format
    tracks = [Map.put(media, "@type", "General")]
    {:ok, tracks}
  end

  # Handle batch MediaInfo format where multiple files are processed
  defp extract_tracks_from_json(json_data) when is_map(json_data) do
    # Check if this is a direct track array (batch processing sometimes returns this)
    case Map.get(json_data, "track") do
      tracks when is_list(tracks) -> {:ok, tracks}
      _ -> extract_tracks_from_media_list(json_data)
    end
  end

  defp extract_tracks_from_json(_), do: {:error, "Invalid MediaInfo JSON structure"}

  defp extract_tracks_from_media_list(json_data) do
    case json_data do
      %{"media" => media_list} when is_list(media_list) ->
        extract_tracks_from_first_media(media_list)

      _ ->
        {:error, "Invalid MediaInfo JSON structure"}
    end
  end

  defp extract_tracks_from_first_media(media_list) do
    case List.first(media_list) do
      %{"track" => tracks} when is_list(tracks) -> {:ok, tracks}
      _ -> {:error, "No valid tracks found in batch MediaInfo"}
    end
  end

  defp find_track_by_type(tracks, track_type) do
    Enum.find(tracks, &(Map.get(&1, "@type") == track_type))
  end

  defp find_tracks_by_type(tracks, track_type) do
    Enum.filter(tracks, &(Map.get(&1, "@type") == track_type))
  end
end
