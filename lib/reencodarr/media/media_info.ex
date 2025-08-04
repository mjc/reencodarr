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
            Duration: String.t() | nil,
            Language: String.t() | nil,
            Default: String.t() | nil,
            Forced: String.t() | nil,
            extra: map() | nil
          }
  end

  defmodule GeneralTrack do
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
            FileSize: String.t() | nil,
            Duration: String.t() | nil,
            OverallBitRate: String.t() | nil,
            FrameRate: String.t() | nil,
            FrameCount: String.t() | nil,
            VideoCount: String.t() | nil,
            AudioCount: String.t() | nil,
            TextCount: String.t() | nil,
            Title: String.t() | nil,
            UniqueID: String.t() | nil,
            extra: map() | nil
          }
  end

  defmodule VideoTrack do
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
            Duration: String.t() | nil,
            Default: String.t() | nil,
            Forced: String.t() | nil,
            Language: String.t() | nil,
            Format: String.t() | nil,
            Format_Profile: String.t() | nil,
            Format_Level: String.t() | nil,
            CodecID: String.t() | nil,
            Width: String.t() | nil,
            Height: String.t() | nil,
            FrameRate: String.t() | nil,
            BitRate: String.t() | nil,
            HDR_Format: String.t() | nil,
            HDR_Format_Compatibility: String.t() | nil,
            ColorSpace: String.t() | nil,
            ChromaSubsampling: String.t() | nil,
            BitDepth: String.t() | nil,
            Encoded_Library: String.t() | nil,
            extra: map() | nil
          }
  end

  defmodule AudioTrack do
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
            Duration: String.t() | nil,
            Default: String.t() | nil,
            Forced: String.t() | nil,
            Language: String.t() | nil,
            Format: String.t() | nil,
            Format_Commercial_IfAny: String.t() | nil,
            CodecID: String.t() | nil,
            BitRate: String.t() | nil,
            Channels: String.t() | nil,
            ChannelPositions: String.t() | nil,
            SamplingRate: String.t() | nil,
            extra: map() | nil
          }
  end

  defmodule TextTrack do
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
            Duration: String.t() | nil,
            Default: String.t() | nil,
            Forced: String.t() | nil,
            Language: String.t() | nil,
            Title: String.t() | nil,
            Format: String.t() | nil,
            CodecID: String.t() | nil,
            BitRate: String.t() | nil,
            FrameRate: String.t() | nil,
            FrameCount: String.t() | nil,
            ElementCount: String.t() | nil,
            StreamSize: String.t() | nil,
            extra: map() | nil
          }
  end

  # Aliases for easier access
  alias __MODULE__.{Media, GeneralTrack, VideoTrack, AudioTrack}

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
        {atomize_key(k), v}
      end

    if map_size(extra_fields) > 0 do
      Map.put(atomized_known, :extra, extra_fields)
    else
      atomized_known
    end
  end

  # Convert string key to atom, handling special characters
  defp atomize_key("@" <> rest), do: String.to_atom("@" <> rest)
  defp atomize_key(key), do: String.to_atom(key)

  # Get list of known field names for a specific struct type
  defp get_known_fields(struct_module) do
    struct_module.__struct__()
    |> Map.keys()
    |> Enum.map(&Atom.to_string/1)
    |> Enum.reject(&(&1 in ["extra", "__struct__"]))
    |> Enum.map(fn
      # Keep @ keys as strings
      "@" <> _ = key -> key
      key -> key
    end)
  end

  def from_video_file_info(%VideoFileInfo{} = info) do
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
            "Height" => elem(info.resolution, 1),
            "Width" => elem(info.resolution, 0),
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

    # Extract structured tracks
    general_track = get_general_track(mediainfo_struct)
    video_tracks = get_video_tracks(mediainfo_struct)
    audio_tracks = get_audio_tracks(mediainfo_struct)

    # Extract video codecs using the structured data
    video_codecs = extract_video_codecs_from_tracks(video_tracks, path, mediainfo_json)

    build_video_params_from_structs(general_track, video_tracks, audio_tracks, video_codecs, path)
  end

  defp get_general_track(%__MODULE__{media: nil}), do: nil

  defp get_general_track(%__MODULE__{media: %Media{track: tracks}}) do
    Enum.find(tracks, fn track ->
      case track do
        %GeneralTrack{} -> true
        _ -> false
      end
    end)
  end

  defp get_video_tracks(%__MODULE__{media: nil}), do: []

  defp get_video_tracks(%__MODULE__{media: %Media{track: tracks}}) do
    Enum.filter(tracks, fn track ->
      case track do
        %VideoTrack{} -> true
        _ -> false
      end
    end)
  end

  defp get_audio_tracks(%__MODULE__{media: nil}), do: []

  defp get_audio_tracks(%__MODULE__{media: %Media{track: tracks}}) do
    Enum.filter(tracks, fn track ->
      case track do
        %AudioTrack{} -> true
        _ -> false
      end
    end)
  end

  defp extract_video_codecs_from_tracks(video_tracks, path, mediainfo_json) do
    require Logger

    video_codecs =
      Enum.map(video_tracks, fn track ->
        case track do
          %VideoTrack{CodecID: codec_id} -> codec_id
          _ -> nil
        end
      end)

    # Log structure in case of issues
    if Enum.empty?(video_tracks) do
      Logger.warning(
        "No video tracks found for #{path}: #{inspect(mediainfo_json, pretty: true, limit: 1000)}"
      )

      Logger.warning("video_codecs will be: #{inspect(video_codecs)}")
    end

    # Additional debugging for video_codecs
    if video_codecs == nil do
      Logger.error("❌ CRITICAL: video_codecs extracted as nil!")
      Logger.error("video_tracks: #{inspect(video_tracks)}")
      Logger.error("Full mediainfo: #{inspect(mediainfo_json, pretty: true, limit: :infinity)}")
      raise "video_codecs is nil after extraction - this indicates a bug"
    end

    video_codecs
  end

  defp build_video_params_from_structs(
         general_track,
         video_tracks,
         audio_tracks,
         video_codecs,
         path
       ) do
    last_video = List.last(video_tracks)

    %{
      "audio_codecs" =>
        Enum.map(audio_tracks, fn track ->
          case track do
            %AudioTrack{CodecID: codec_id} -> codec_id
            _ -> nil
          end
        end),
      "audio_count" => parse_int_from_struct(general_track, :AudioCount, 0),
      "atmos" => has_atmos_from_structs?(audio_tracks),
      "bitrate" => parse_int_from_struct(general_track, :OverallBitRate, 0),
      "duration" => parse_float_from_struct(general_track, :Duration, 0.0),
      "frame_rate" => parse_float_from_video_struct(last_video, :FrameRate, 0.0),
      "hdr" => parse_hdr_from_video_struct(last_video),
      "height" => parse_int_from_video_struct(last_video, :Height, 0),
      "max_audio_channels" => max_audio_channels_from_structs(audio_tracks),
      "size" => parse_int_from_struct(general_track, :FileSize, 0),
      "text_count" => parse_int_from_struct(general_track, :TextCount, 0),
      "video_codecs" => video_codecs,
      "video_count" => parse_int_from_struct(general_track, :VideoCount, 0),
      "width" => parse_int_from_video_struct(last_video, :Width, 0),
      "reencoded" =>
        reencoded?(video_codecs, %{
          "media" => %{"track" => tracks_to_maps(general_track, video_tracks, audio_tracks)}
        }),
      "title" => get_title_from_struct(general_track, path)
    }
  end

  defp parse_int_from_struct(nil, _field, default), do: default

  defp parse_int_from_struct(struct, field, default) do
    case Map.get(struct, field) do
      nil -> default
      value when is_integer(value) -> value
      value when is_binary(value) -> CodecHelper.parse_int(value, default)
      _ -> default
    end
  end

  defp parse_float_from_struct(nil, _field, default), do: default

  defp parse_float_from_struct(struct, field, default) do
    case Map.get(struct, field) do
      nil -> default
      value when is_float(value) -> value
      value when is_binary(value) -> CodecHelper.parse_float(value, default)
      _ -> default
    end
  end

  defp parse_int_from_video_struct(nil, _field, default), do: default

  defp parse_int_from_video_struct(%VideoTrack{} = track, field, default) do
    parse_int_from_struct(track, field, default)
  end

  defp parse_float_from_video_struct(nil, _field, default), do: default

  defp parse_float_from_video_struct(%VideoTrack{} = track, field, default) do
    parse_float_from_struct(track, field, default)
  end

  defp parse_hdr_from_video_struct(nil), do: nil

  defp parse_hdr_from_video_struct(%VideoTrack{HDR_Format: hdr_format}) do
    CodecHelper.parse_hdr_from_map(%{"HDR_Format" => hdr_format})
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

  defp max_audio_channels_from_structs(audio_tracks) do
    audio_tracks
    |> Enum.map(fn track ->
      case track do
        %AudioTrack{Channels: channels} ->
          CodecHelper.parse_int(channels, 0)

        _ ->
          0
      end
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp get_title_from_struct(nil, path), do: Path.basename(path)

  defp get_title_from_struct(%GeneralTrack{Title: title}, _path) when is_binary(title) do
    title
  end

  defp get_title_from_struct(_, path), do: Path.basename(path)

  # Convert structured tracks back to maps for compatibility with existing reencoded? function
  defp tracks_to_maps(general_track, video_tracks, audio_tracks) do
    general_map =
      case general_track do
        %GeneralTrack{} = track ->
          track
          |> Map.from_struct()
          |> Map.put("@type", "General")
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Enum.into(%{})

        _ ->
          %{"@type" => "General"}
      end

    video_maps =
      Enum.map(video_tracks, fn track ->
        case track do
          %VideoTrack{} = video_track ->
            video_track
            |> Map.from_struct()
            |> Map.put("@type", "Video")
            |> Enum.reject(fn {_k, v} -> is_nil(v) end)
            |> Enum.into(%{})

          _ ->
            %{"@type" => "Video"}
        end
      end)

    audio_maps =
      Enum.map(audio_tracks, fn track ->
        case track do
          %AudioTrack{} = audio_track ->
            audio_track
            |> Map.from_struct()
            |> Map.put("@type", "Audio")
            |> Enum.reject(fn {_k, v} -> is_nil(v) end)
            |> Enum.into(%{})

          _ ->
            %{"@type" => "Audio"}
        end
      end)

    [general_map] ++ video_maps ++ audio_maps
  end

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
end
