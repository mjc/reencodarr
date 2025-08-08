defmodule Reencodarr.Media.MediaInfo do
  @moduledoc """
  Logic for converting between VideoFileInfo structs and mediainfo maps, and extracting params for Ecto changesets.
  """
  alias Reencodarr.Media.{CodecHelper, CodecMapper, VideoFileInfo}

  @derive Jason.Encoder
  defstruct [
    :creatingLibrary,
    :media
  ]

  @type t :: %__MODULE__{
          creatingLibrary: CreatingLibrary.t(),
          media: Media.t()
        }

  defmodule CreatingLibrary do
    @moduledoc """
    Represents the creating library information from MediaInfo.
    """
    @derive Jason.Encoder
    defstruct [
      :name,
      :version,
      :url
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            version: String.t(),
            url: String.t()
          }
  end

  defmodule Media do
    @moduledoc """
    Represents media container information from MediaInfo.
    """
    @derive Jason.Encoder
    defstruct [
      :"@ref",
      :track
    ]

    @type t :: %__MODULE__{
            "@ref": String.t(),
            track: [Track.t()]
          }
  end

  defmodule Track do
    @moduledoc """
    Represents a generic track from MediaInfo.
    """
    @derive Jason.Encoder
    defstruct [
      :"@type",
      :"@typeorder",
      :StreamOrder,
      :ID,
      :UniqueID,
      :Format,
      :Duration,
      :Language,
      :Default,
      :Forced,
      :extra
    ]

    @type t :: %__MODULE__{
            "@type": String.t(),
            "@typeorder": String.t() | nil,
            StreamOrder: String.t() | nil,
            ID: String.t() | nil,
            UniqueID: String.t() | nil,
            Format: String.t() | nil,
            Duration: float() | nil,
            Language: String.t() | nil,
            Default: String.t() | nil,
            Forced: String.t() | nil,
            extra: map() | nil
          }
  end

  defmodule GeneralTrack do
    @moduledoc """
    Represents general track information from MediaInfo.
    """
    @derive Jason.Encoder
    defstruct [
      :"@type",
      :FileExtension,
      :Format,
      :Format_Profile,
      :Format_Version,
      :CodecID,
      :CodecID_Compatible,
      :FileSize,
      :Duration,
      :OverallBitRate,
      :FrameRate,
      :FrameCount,
      :VideoCount,
      :AudioCount,
      :TextCount,
      :Title,
      :UniqueID,
      :extra
    ]

    @type t :: %__MODULE__{
            "@type": String.t(),
            FileExtension: String.t() | nil,
            Format: String.t() | nil,
            Format_Profile: String.t() | nil,
            Format_Version: String.t() | nil,
            CodecID: String.t() | nil,
            CodecID_Compatible: String.t() | nil,
            FileSize: integer() | nil,
            Duration: float() | nil,
            OverallBitRate: integer() | nil,
            FrameRate: float() | nil,
            FrameCount: integer() | nil,
            VideoCount: integer() | nil,
            AudioCount: integer() | nil,
            TextCount: integer() | nil,
            Title: String.t() | nil,
            UniqueID: String.t() | nil,
            extra: map() | nil
          }
  end

  defmodule VideoTrack do
    @moduledoc """
    Represents a video track from MediaInfo.
    """
    @derive Jason.Encoder
    defstruct [
      :"@type",
      :StreamOrder,
      :ID,
      :UniqueID,
      :Duration,
      :Default,
      :Forced,
      :Language,
      :Format,
      :Format_Profile,
      :Format_Level,
      :CodecID,
      :Width,
      :Height,
      :FrameRate,
      :BitRate,
      :HDR_Format,
      :HDR_Format_Compatibility,
      :ColorSpace,
      :ChromaSubsampling,
      :BitDepth,
      :Encoded_Library,
      :extra
    ]

    @type t :: %__MODULE__{
            "@type": String.t(),
            StreamOrder: String.t() | nil,
            ID: String.t() | nil,
            UniqueID: String.t() | nil,
            Duration: float() | nil,
            Default: String.t() | nil,
            Forced: String.t() | nil,
            Language: String.t() | nil,
            Format: String.t() | nil,
            Format_Profile: String.t() | nil,
            Format_Level: String.t() | nil,
            CodecID: String.t() | nil,
            Width: integer() | nil,
            Height: integer() | nil,
            FrameRate: float() | nil,
            BitRate: integer() | nil,
            HDR_Format: String.t() | nil,
            HDR_Format_Compatibility: String.t() | nil,
            ColorSpace: String.t() | nil,
            ChromaSubsampling: String.t() | nil,
            BitDepth: integer() | nil,
            Encoded_Library: String.t() | nil,
            extra: map() | nil
          }
  end

  defmodule AudioTrack do
    @moduledoc """
    Represents an audio track from MediaInfo.
    """
    @derive Jason.Encoder
    defstruct [
      :"@type",
      :StreamOrder,
      :ID,
      :UniqueID,
      :Duration,
      :Default,
      :Forced,
      :Language,
      :Format,
      :Format_Commercial_IfAny,
      :CodecID,
      :BitRate,
      :Channels,
      :ChannelPositions,
      :SamplingRate,
      :extra
    ]

    @type t :: %__MODULE__{
            "@type": String.t(),
            StreamOrder: String.t() | nil,
            ID: String.t() | nil,
            UniqueID: String.t() | nil,
            Duration: float() | nil,
            Default: String.t() | nil,
            Forced: String.t() | nil,
            Language: String.t() | nil,
            Format: String.t() | nil,
            Format_Commercial_IfAny: String.t() | nil,
            CodecID: String.t() | nil,
            BitRate: integer() | nil,
            Channels: String.t() | nil,
            ChannelPositions: String.t() | nil,
            SamplingRate: integer() | nil,
            extra: map() | nil
          }
  end

  defmodule TextTrack do
    @moduledoc """
    Represents a text/subtitle track from MediaInfo.
    """
    @derive Jason.Encoder
    defstruct [
      :"@type",
      :"@typeorder",
      :StreamOrder,
      :ID,
      :UniqueID,
      :Duration,
      :Default,
      :Forced,
      :Language,
      :Title,
      :Format,
      :CodecID,
      :BitRate,
      :FrameRate,
      :FrameCount,
      :ElementCount,
      :StreamSize,
      :extra
    ]

    @type t :: %__MODULE__{
            "@type": String.t(),
            "@typeorder": String.t() | nil,
            StreamOrder: String.t() | nil,
            ID: String.t() | nil,
            UniqueID: String.t() | nil,
            Duration: float() | nil,
            Default: String.t() | nil,
            Forced: String.t() | nil,
            Language: String.t() | nil,
            Title: String.t() | nil,
            Format: String.t() | nil,
            CodecID: String.t() | nil,
            BitRate: integer() | nil,
            FrameRate: float() | nil,
            FrameCount: integer() | nil,
            ElementCount: integer() | nil,
            StreamSize: integer() | nil,
            extra: map() | nil
          }
  end

  # Aliases for easier access
  alias __MODULE__.{Media, GeneralTrack, VideoTrack, AudioTrack, TextTrack}
  alias Reencodarr.Media.TrackProtocol

  @doc """
  Converts raw MediaInfo JSON into structured MediaInfo.
  """
  @spec from_json(map() | list() | nil) :: [t()] | {:error, term()}
  def from_json(nil), do: [%__MODULE__{creatingLibrary: nil, media: nil}]

  def from_json(json_data) when is_list(json_data) do
    Enum.map(json_data, &parse_single_media_info/1)
  end

  def from_json(json_data) when is_map(json_data) do
    [parse_single_media_info(json_data)]
  end

  # Handle the full MediaInfo JSON format with creatingLibrary
  defp parse_single_media_info(%{"creatingLibrary" => creating_lib, "media" => media}) do
    %__MODULE__{
      creatingLibrary: parse_creating_library(creating_lib),
      media: parse_media(media)
    }
  end

  # Handle legacy format that only has media data (from tests)
  defp parse_single_media_info(%{"media" => media}) do
    %__MODULE__{
      creatingLibrary: nil,
      media: parse_media(media)
    }
  end

  # Handle empty map
  defp parse_single_media_info(%{}) do
    %__MODULE__{
      creatingLibrary: nil,
      media: nil
    }
  end

  defp parse_creating_library(nil), do: nil

  defp parse_creating_library(%{"name" => name, "version" => version, "url" => url}) do
    %CreatingLibrary{
      name: name,
      version: version,
      url: url
    }
  end

  defp parse_media(nil), do: nil

  defp parse_media(%{"@ref" => ref, "track" => tracks}) when is_list(tracks) do
    %Media{
      "@ref": ref,
      track: Enum.map(tracks, &parse_track/1)
    }
  end

  defp parse_media(%{"track" => tracks}) when is_list(tracks) do
    %Media{
      "@ref": nil,
      track: Enum.map(tracks, &parse_track/1)
    }
  end

  defp parse_track(%{"@type" => "General"} = track_data) do
    struct(GeneralTrack, atomize_keys_with_extra(track_data, GeneralTrack))
  end

  defp parse_track(%{"@type" => "Video"} = track_data) do
    struct(VideoTrack, atomize_keys_with_extra(track_data, VideoTrack))
  end

  defp parse_track(%{"@type" => "Audio"} = track_data) do
    struct(AudioTrack, atomize_keys_with_extra(track_data, AudioTrack))
  end

  defp parse_track(%{"@type" => "Text"} = track_data) do
    struct(TextTrack, atomize_keys_with_extra(track_data, TextTrack))
  end

  defp parse_track(track_data) do
    struct(Track, atomize_keys_with_extra(track_data, Track))
  end

  # Convert string keys to atoms, handling known fields and putting unknown fields in :extra
  defp atomize_keys_with_extra(map, struct_module) do
    known_fields = get_known_fields(struct_module)
    {known_fields_map, extra_fields} = Map.split(map, known_fields)

    atomized_known =
      for {k, v} <- known_fields_map, into: %{} do
        atom_key = atomize_key(k)
        converted_value = convert_field_value(atom_key, v, struct_module)
        {atom_key, converted_value}
      end

    if map_size(extra_fields) > 0 do
      Map.put(atomized_known, :extra, extra_fields)
    else
      atomized_known
    end
  end

  # Convert string key to atom, handling special characters
  defp atomize_key(key), do: String.to_atom(key)

  # Convert field values to appropriate types based on the field and struct type
  defp convert_field_value(_field, value, _struct_module) when is_nil(value), do: nil

  defp convert_field_value(_field, value, _struct_module)
       when is_binary(value) and byte_size(value) == 0, do: nil

  # Integer fields
  defp convert_field_value(field, value, _struct_module)
       when field in [
              :FileSize,
              :OverallBitRate,
              :FrameCount,
              :VideoCount,
              :AudioCount,
              :TextCount,
              :Width,
              :Height,
              :BitRate,
              :BitDepth,
              :SamplingRate,
              :Channels
            ] do
    case value do
      int when is_integer(int) -> int
      str when is_binary(str) -> CodecHelper.parse_int(str, 0)
      _ -> 0
    end
  end

  # Float fields
  defp convert_field_value(field, value, _struct_module)
       when field in [
              :Duration,
              :FrameRate
            ] do
    case value do
      float when is_float(float) -> float
      int when is_integer(int) -> int / 1.0
      str when is_binary(str) -> CodecHelper.parse_float(str, 0.0)
      _ -> 0.0
    end
  end

  # String fields (default case)
  defp convert_field_value(_field, value, _struct_module), do: value

  # Get list of known field names for a specific struct type
  defp get_known_fields(struct_module) do
    struct_module.__struct__()
    |> Map.keys()
    |> Enum.map(&Atom.to_string/1)
    |> Enum.reject(&(&1 in ["extra", "__struct__"]))
  end

  @doc """
  Converts VideoFileInfo struct to MediaInfo JSON format for database storage.
  """
  def from_video_file_info(%VideoFileInfo{} = info) do
    {width, height} = parse_resolution(info.resolution)

    %{
      "media" => %{
        "track" => [
          %{
            "@type" => "General",
            "AudioCount" => info.audio_stream_count,
            "OverallBitRate" => info.overall_bitrate || info.bitrate,
            "Duration" => CodecHelper.parse_duration(info.run_time),
            "FileSize" => info.size,
            "TextCount" => length(info.subtitles || []),
            "VideoCount" => 1,
            "Title" => info.title
          },
          %{
            "@type" => "Video",
            "FrameRate" => info.video_fps,
            "Height" => height,
            "Width" => width,
            "HDR_Format" => info.video_dynamic_range,
            "HDR_Format_Compatibility" => info.video_dynamic_range_type,
            "CodecID" => info.video_codec
          },
          %{
            "@type" => "Audio",
            "CodecID" => info.audio_codec,
            "Channels" => to_string(info.audio_channels),
            "Format_Commercial_IfAny" => CodecMapper.format_commercial_if_any(info.audio_codec)
          }
        ]
      }
    }
  end

  @doc """
  Converts raw Sonarr/Radarr file data directly to MediaInfo struct.
  This is the most efficient path for service integration.
  """
  def from_service_file_to_struct(file, service_type) when service_type in [:sonarr, :radarr] do
    file
    |> from_service_file(service_type)
    |> from_json()
    # Get the first (and only) MediaInfo struct from the list
    |> hd()
  end

  @doc """
  Converts VideoFileInfo struct to MediaInfo struct via JSON transformation.
  """
  def from_video_file_info_to_struct(%VideoFileInfo{} = info) do
    info
    |> from_video_file_info()
    |> from_json()
    # Get the first (and only) MediaInfo struct from the list
    |> hd()
  end

  @doc """
  Converts raw Sonarr/Radarr file data directly to MediaInfo JSON format.
  This bypasses the VideoFileInfo struct for simpler processing.
  """
  def from_service_file(file, service_type) when service_type in [:sonarr, :radarr] do
    media_info = file["mediaInfo"] || %{}

    {width, height} = parse_resolution_from_service(media_info)
    overall_bitrate = calculate_overall_bitrate(file, media_info)
    subtitles = parse_subtitles_from_service(media_info)
    audio_languages = parse_audio_languages_from_service(media_info)

    %{
      "media" => %{
        "track" => [
          build_general_track(file, overall_bitrate, subtitles, audio_languages),
          build_video_track(file, media_info, width, height),
          build_audio_track(media_info)
        ]
      }
    }
  end

  # Helper functions for from_service_file/2
  defp parse_resolution_from_service(media_info) do
    case {media_info["width"], media_info["height"]} do
      {w, h} when is_integer(w) and is_integer(h) ->
        {w, h}

      {w, h} when is_binary(w) and is_binary(h) ->
        with {width_int, ""} <- Integer.parse(w),
             {height_int, ""} <- Integer.parse(h) do
          {width_int, height_int}
        else
          _ -> {0, 0}
        end

      _ ->
        {0, 0}
    end
  end

  defp calculate_overall_bitrate(file, media_info) do
    case {file["overallBitrate"], media_info["videoBitrate"], media_info["audioBitrate"]} do
      {overall, _, _} when is_integer(overall) and overall > 0 -> overall
      {_, video, audio} when is_integer(video) and is_integer(audio) -> video + audio
      {_, video, _} when is_integer(video) -> video
      _ -> 0
    end
  end

  defp parse_subtitles_from_service(media_info) do
    case media_info["subtitles"] do
      list when is_list(list) -> list
      binary when is_binary(binary) -> String.split(binary, "/")
      _ -> []
    end
  end

  defp parse_audio_languages_from_service(media_info) do
    case media_info["audioLanguages"] do
      list when is_list(list) -> list
      binary when is_binary(binary) -> String.split(binary, "/")
      _ -> []
    end
  end

  defp build_general_track(file, overall_bitrate, subtitles, audio_languages) do
    %{
      "@type" => "General",
      "AudioCount" => length(audio_languages),
      "OverallBitRate" => overall_bitrate,
      "Duration" => file["runTime"],
      "FileSize" => file["size"],
      "TextCount" => length(subtitles),
      "VideoCount" => 1,
      "Title" => file["sceneName"] || file["title"]
    }
  end

  defp build_video_track(file, media_info, width, height) do
    %{
      "@type" => "Video",
      "FrameRate" => file["videoFps"] || media_info["videoFps"],
      "Height" => height,
      "Width" => width,
      "HDR_Format" => media_info["videoDynamicRange"],
      "HDR_Format_Compatibility" => media_info["videoDynamicRangeType"],
      "CodecID" => media_info["videoCodec"]
    }
  end

  defp build_audio_track(media_info) do
    %{
      "@type" => "Audio",
      "CodecID" => media_info["audioCodec"],
      "Channels" => media_info["audioChannels"],
      "Format_Commercial_IfAny" => CodecMapper.format_commercial_if_any(media_info["audioCodec"])
    }
  end

  def to_video_params(mediainfo_json, path) when is_list(mediainfo_json) do
    # Handle case where MediaInfo returns array with single item
    case mediainfo_json do
      [single_item] -> to_video_params(single_item, path)
      _ -> raise "Multiple media items not supported"
    end
  end

  def to_video_params(mediainfo_json, path) do
    require Logger

    # Convert raw JSON to structured data
    [mediainfo_struct] = from_json(mediainfo_json)

    # Extract structured tracks using protocol-based extraction
    general_track = extract_first_track(mediainfo_struct, :general)
    video_tracks = extract_tracks_by_type(mediainfo_struct, :video)
    audio_tracks = extract_tracks_by_type(mediainfo_struct, :audio)

    # Extract video codecs using the structured data
    video_codecs = extract_codec_ids(mediainfo_struct, :video)

    case build_video_params_from_structs(
           general_track,
           video_tracks,
           audio_tracks,
           video_codecs,
           path
         ) do
      {:ok, params} ->
        params

      {:error, reason} ->
        Logger.error("Failed to build video params for #{path}: #{reason}")
        raise "Invalid audio metadata: #{reason}"
    end
  end

  defp build_video_params_from_structs(
         general_track,
         video_tracks,
         audio_tracks,
         video_codecs,
         path
       ) do
    last_video = List.last(video_tracks)

    # Validate audio channel information
    case validate_audio_channels(audio_tracks, general_track) do
      {:ok, max_channels} ->
        # Build successful params
        {:ok,
         %{
           "audio_codecs" => Enum.map(audio_tracks, &TrackProtocol.codec_id/1),
           "audio_count" => get_field_value(general_track, :AudioCount, 0),
           "atmos" => has_atmos_from_structs?(audio_tracks),
           "bitrate" => get_field_value(general_track, :OverallBitRate, 0),
           "duration" => get_field_value(general_track, :Duration, 0.0),
           "frame_rate" => get_field_value(last_video, :FrameRate, 0.0),
           "hdr" => get_hdr_from_video_track(last_video),
           "height" => get_field_value(last_video, :Height, 0),
           "max_audio_channels" => max_channels,
           "size" => get_field_value(general_track, :FileSize, 0),
           "text_count" => get_field_value(general_track, :TextCount, 0),
           "video_codecs" => video_codecs,
           "video_count" => get_field_value(general_track, :VideoCount, 0),
           "width" => get_field_value(last_video, :Width, 0),
           "reencoded" =>
             reencoded?(video_codecs, %{
               "media" => %{
                 "track" => tracks_to_legacy_maps(general_track, video_tracks, audio_tracks)
               }
             }),
           "title" => get_title_from_struct(general_track, path)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Simplified field access since values are already properly typed
  defp get_field_value(nil, _field, default), do: default

  defp get_field_value(struct, field, default) do
    Map.get(struct, field, default)
  end

  @doc """
  Extracts normalized metadata from a track using the Track Protocol.

  This provides a unified way to get metadata regardless of track type.
  """
  def extract_track_metadata(track) do
    TrackProtocol.extract_metadata(track)
  end

  @doc """
  Validates a track using the Track Protocol.

  Returns true if the track has valid required fields for its type.
  """
  def validate_track(track) do
    TrackProtocol.valid?(track)
  end

  defp has_atmos_from_structs?(audio_tracks) do
    Enum.any?(audio_tracks, fn track ->
      case track do
        %AudioTrack{Format_Commercial_IfAny: format} ->
          CodecHelper.has_atmos_format?(format)

        _ ->
          false
      end
    end)
  end

  # Validate that audio tracks have valid channel information
  defp validate_audio_channels(audio_tracks, general_track) do
    audio_count = get_field_value(general_track, :AudioCount, 0)

    # If MediaInfo reports audio tracks but we have no audio track data, that's an error
    if audio_count > 0 and Enum.empty?(audio_tracks) do
      {:error, "MediaInfo reports #{audio_count} audio tracks but no audio track data found"}
    else
      validate_channel_data(audio_tracks)
    end
  end

  defp validate_channel_data(audio_tracks) do
    max_channels = max_audio_channels_from_structs(audio_tracks)

    # If we have audio tracks but all have 0 or invalid channels, that's suspicious
    if not Enum.empty?(audio_tracks) and max_channels == 0 do
      build_invalid_channels_error(audio_tracks)
    else
      {:ok, max_channels}
    end
  end

  defp build_invalid_channels_error(audio_tracks) do
    invalid_tracks = format_invalid_track_descriptions(audio_tracks)
    {:error, "All audio tracks have invalid channel data: #{Enum.join(invalid_tracks, ", ")}"}
  end

  defp format_invalid_track_descriptions(audio_tracks) do
    audio_tracks
    |> Enum.with_index()
    |> Enum.filter(&track_has_invalid_channels?/1)
    |> Enum.map(&format_track_description/1)
  end

  defp track_has_invalid_channels?({track, _idx}) do
    case track do
      %AudioTrack{Channels: channels} when is_integer(channels) and channels > 0 ->
        false

      %AudioTrack{Channels: channels} when is_binary(channels) ->
        CodecHelper.parse_int(channels, 0) == 0

      _ ->
        true
    end
  end

  defp format_track_description({track, idx}) do
    channels_val =
      case track do
        %AudioTrack{Channels: channels} -> inspect(channels)
        _ -> "missing"
      end

    "track #{idx}: #{channels_val}"
  end

  defp max_audio_channels_from_structs(audio_tracks) do
    audio_tracks
    |> Enum.map(fn track ->
      case track do
        %AudioTrack{Channels: channels} when is_integer(channels) and channels > 0 ->
          channels

        %AudioTrack{Channels: channels} when is_binary(channels) ->
          CodecHelper.parse_int(channels, 0)

        %AudioTrack{Channels: channels} when is_nil(channels) ->
          0

        _ ->
          0
      end
    end)
    |> case do
      [] -> 0
      channel_counts -> Enum.max(channel_counts)
    end
  end

  defp get_title_from_struct(nil, path), do: Path.basename(path)

  defp get_title_from_struct(%GeneralTrack{Title: title}, _path) when is_binary(title) do
    title
  end

  defp get_title_from_struct(_, path), do: Path.basename(path)

  def reencoded?(video_codecs, mediainfo),
    do:
      CodecMapper.has_av1_codec?(video_codecs) or
        CodecMapper.has_opus_audio?(mediainfo) or
        CodecMapper.low_bitrate_1080p?(video_codecs, mediainfo) or
        CodecMapper.has_low_resolution_hevc?(video_codecs, mediainfo)

  def video_file_info_from_file(file, service_type) do
    media = file["mediaInfo"] || %{}
    {width, height} = CodecHelper.parse_resolution(media["resolution"])

    %VideoFileInfo{
      path: file["path"],
      size: file["size"],
      service_id: to_string(file["id"]),
      service_type: service_type,
      audio_codec: CodecMapper.map_codec_id(media["audioCodec"]),
      video_codec: CodecMapper.map_codec_id(media["videoCodec"]),
      bitrate: media["overallBitrate"] || media["videoBitrate"],
      audio_channels: CodecMapper.map_channels_with_context(media["audioChannels"], media),
      resolution: {width, height},
      video_fps: media["videoFps"],
      video_dynamic_range: media["videoDynamicRange"],
      video_dynamic_range_type: media["videoDynamicRangeType"],
      audio_stream_count: media["audioStreamCount"],
      overall_bitrate: media["overallBitrate"],
      run_time: media["runTime"],
      subtitles: CodecHelper.parse_subtitles(media["subtitles"]),
      title: file["title"]
    }
  end

  # Helper functions for extracting data from MediaInfo structs

  @doc """
  Extracts tracks of a specific type using the TrackProtocol.

  ## Examples

      iex> extract_tracks_by_type(media_info, :video)
      [%VideoTrack{}, ...]

      iex> extract_tracks_by_type(media_info, :audio)
      [%AudioTrack{}, ...]
  """
  def extract_tracks_by_type(%__MODULE__{media: %Media{track: tracks}}, track_type)
      when is_list(tracks) do
    Enum.filter(tracks, &(TrackProtocol.track_type(&1) == track_type))
  end

  def extract_tracks_by_type(_, _), do: []

  @doc """
  Extracts the first track of a specific type.

  ## Examples

      iex> extract_first_track(media_info, :general)
      %GeneralTrack{}

      iex> extract_first_track(media_info, :video)
      %VideoTrack{}
  """
  def extract_first_track(media_info, track_type) do
    media_info
    |> extract_tracks_by_type(track_type)
    |> List.first()
  end

  @doc """
  Gets all tracks from MediaInfo struct.
  """
  def get_all_tracks(%__MODULE__{media: %Media{track: tracks}}) when is_list(tracks), do: tracks
  def get_all_tracks(_), do: []

  @doc """
  Extracts codec IDs from tracks of a specific type.

  ## Examples

      iex> extract_codec_ids(media_info, :video)
      ["h264", "hevc"]

      iex> extract_codec_ids(media_info, :audio)
      ["aac", "eac3"]
  """
  def extract_codec_ids(media_info, track_type) do
    media_info
    |> extract_tracks_by_type(track_type)
    |> Enum.map(&TrackProtocol.codec_id/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Converts all tracks to legacy map format for compatibility.
  """
  def tracks_to_legacy_maps(general_track, video_tracks, audio_tracks) do
    general_map =
      if general_track,
        do: TrackProtocol.to_legacy_map(general_track),
        else: %{"@type" => "General"}

    video_maps = Enum.map(video_tracks, &TrackProtocol.to_legacy_map/1)
    audio_maps = Enum.map(audio_tracks, &TrackProtocol.to_legacy_map/1)

    [general_map] ++ video_maps ++ audio_maps
  end

  # Legacy extraction functions - now implemented using protocol
  @doc """
  Extracts the first video track from a MediaInfo struct.
  """
  def extract_video_track(media_info), do: extract_first_track(media_info, :video)

  @doc """
  Extracts the first audio track from a MediaInfo struct.
  """
  def extract_audio_track(media_info), do: extract_first_track(media_info, :audio)

  @doc """
  Extracts the general track from a MediaInfo struct.
  """
  def extract_general_track(media_info), do: extract_first_track(media_info, :general)

  @doc """
  Gets the resolution as a tuple from a video track.
  """
  def get_resolution(%VideoTrack{} = track) do
    metadata = TrackProtocol.extract_metadata(track)
    {metadata.width || 0, metadata.height || 0}
  end

  def get_resolution(_), do: {0, 0}

  @doc """
  Gets the video codec from a video track.
  """
  def get_video_codec(track), do: TrackProtocol.codec_id(track)

  @doc """
  Gets the audio codec from an audio track.
  """
  def get_audio_codec(track), do: TrackProtocol.codec_id(track)

  @doc """
  Gets the audio channels from an audio track.
  """
  def get_audio_channels(%AudioTrack{} = track) do
    metadata = TrackProtocol.extract_metadata(track)
    metadata.channels
  end

  def get_audio_channels(_), do: nil

  @doc """
  Gets the frame rate from a video track.
  """
  def get_fps(%VideoTrack{} = track) do
    metadata = TrackProtocol.extract_metadata(track)
    metadata.frame_rate
  end

  def get_fps(_), do: nil

  @doc """
  Gets the overall bitrate from a general track.
  """
  def get_overall_bitrate(%GeneralTrack{} = track) do
    metadata = TrackProtocol.extract_metadata(track)
    metadata.overall_bitrate || 0
  end

  def get_overall_bitrate(_), do: 0

  @doc """
  Gets the audio count from a general track.
  """
  def get_audio_count(%GeneralTrack{} = track) do
    metadata = TrackProtocol.extract_metadata(track)
    metadata.audio_count || 0
  end

  def get_audio_count(_), do: 0

  @doc """
  Gets the duration from a general track.
  """
  def get_duration(%GeneralTrack{} = track) do
    metadata = TrackProtocol.extract_metadata(track)
    if metadata.duration, do: round(metadata.duration), else: 0
  end

  def get_duration(_), do: 0

  @doc """
  Gets the HDR format from a video track.
  """
  def get_hdr_format(%VideoTrack{} = track) do
    metadata = TrackProtocol.extract_metadata(track)
    metadata.hdr_format
  end

  def get_hdr_format(_), do: nil

  @doc """
  Gets the HDR format compatibility from a video track.
  """
  def get_hdr_format_compatibility(%VideoTrack{} = track) do
    metadata = TrackProtocol.extract_metadata(track)
    metadata.hdr_format_compatibility
  end

  def get_hdr_format_compatibility(_), do: nil

  @doc """
  Gets the HDR information from a video track, parsing it using CodecHelper.
  """
  def get_hdr_from_video_track(%VideoTrack{HDR_Format: hdr_format}) do
    CodecHelper.parse_hdr_from_map(%{"HDR_Format" => hdr_format})
  end

  def get_hdr_from_video_track(_), do: nil

  # Helper function to parse resolution from either tuple or string
  defp parse_resolution({width, height}) when is_integer(width) and is_integer(height) do
    {width, height}
  end

  defp parse_resolution(resolution) when is_binary(resolution) do
    case String.split(resolution, "x") do
      [width_str, height_str] ->
        width = CodecHelper.parse_int(width_str, 0)
        height = CodecHelper.parse_int(height_str, 0)
        {width, height}

      _ ->
        {0, 0}
    end
  end

  defp parse_resolution(_), do: {0, 0}

  @doc """
  Parses a subtitle list, returning an empty list if nil.
  """
  def parse_subtitle_list(nil), do: []
  def parse_subtitle_list(list) when is_list(list), do: list
  def parse_subtitle_list(_), do: []
end
