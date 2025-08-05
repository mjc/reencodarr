defprotocol Reencodarr.Media.TrackProtocol do
  @moduledoc """
  Protocol for standardizing track behavior across all MediaInfo track types.

  This protocol provides a unified interface for:
  - Track type identification
  - Metadata extraction
  - Track validation
  - Codec identification

  Eliminates duplicate extraction logic and provides type-safe track operations.
  """

  @doc """
  Gets the track type as an atom.

  ## Examples

      iex> TrackProtocol.track_type(%GeneralTrack{})
      :general
      
      iex> TrackProtocol.track_type(%VideoTrack{})
      :video
  """
  @spec track_type(term()) :: atom()
  def track_type(track)

  @doc """
  Extracts key metadata from a track in a standardized format.

  Returns a map with normalized keys and properly typed values.
  """
  @spec extract_metadata(term()) :: map()
  def extract_metadata(track)

  @doc """
  Validates if track has required fields for its type.

  Returns true if the track contains the minimum required data.
  """
  @spec valid?(term()) :: boolean()
  def valid?(track)

  @doc """
  Gets the codec identifier from a track, if applicable.

  Returns nil for tracks that don't have codec information.
  """
  @spec codec_id(term()) :: String.t() | nil
  def codec_id(track)

  @doc """
  Converts track back to legacy map format for compatibility.

  Used for interfacing with existing code that expects map format.
  """
  @spec to_legacy_map(term()) :: map()
  def to_legacy_map(track)
end

# Protocol implementations
alias Reencodarr.Media.MediaInfo.{GeneralTrack, VideoTrack, AudioTrack, TextTrack, Track}

defimpl Reencodarr.Media.TrackProtocol, for: GeneralTrack do
  def track_type(_), do: :general

  def extract_metadata(%GeneralTrack{} = track) do
    %{
      file_size: Map.get(track, :FileSize),
      duration: Map.get(track, :Duration),
      overall_bitrate: Map.get(track, :OverallBitRate),
      frame_rate: Map.get(track, :FrameRate),
      frame_count: Map.get(track, :FrameCount),
      video_count: Map.get(track, :VideoCount),
      audio_count: Map.get(track, :AudioCount),
      text_count: Map.get(track, :TextCount),
      title: Map.get(track, :Title),
      format: Map.get(track, :Format),
      file_extension: Map.get(track, :FileExtension)
    }
  end

  def valid?(%GeneralTrack{} = track) do
    not is_nil(Map.get(track, :FileSize)) or not is_nil(Map.get(track, :Duration))
  end

  def codec_id(%GeneralTrack{} = track), do: Map.get(track, :CodecID)

  def to_legacy_map(%GeneralTrack{} = track) do
    track
    |> Map.from_struct()
    |> Map.put("@type", "General")
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end
end

defimpl Reencodarr.Media.TrackProtocol, for: VideoTrack do
  def track_type(_), do: :video

  def extract_metadata(%VideoTrack{} = track) do
    %{
      width: Map.get(track, :Width),
      height: Map.get(track, :Height),
      frame_rate: Map.get(track, :FrameRate),
      bitrate: Map.get(track, :BitRate),
      duration: Map.get(track, :Duration),
      format: Map.get(track, :Format),
      format_profile: Map.get(track, :Format_Profile),
      format_level: Map.get(track, :Format_Level),
      hdr_format: Map.get(track, :HDR_Format),
      hdr_format_compatibility: Map.get(track, :HDR_Format_Compatibility),
      color_space: Map.get(track, :ColorSpace),
      chroma_subsampling: Map.get(track, :ChromaSubsampling),
      bit_depth: Map.get(track, :BitDepth),
      language: Map.get(track, :Language)
    }
  end

  def valid?(%VideoTrack{} = track) do
    not is_nil(Map.get(track, :Width)) and not is_nil(Map.get(track, :Height))
  end

  def codec_id(%VideoTrack{} = track), do: Map.get(track, :CodecID)

  def to_legacy_map(%VideoTrack{} = track) do
    track
    |> Map.from_struct()
    |> Map.put("@type", "Video")
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end
end

defimpl Reencodarr.Media.TrackProtocol, for: AudioTrack do
  def track_type(_), do: :audio

  def extract_metadata(%AudioTrack{} = track) do
    %{
      format: Map.get(track, :Format),
      format_commercial: Map.get(track, :Format_Commercial_IfAny),
      bitrate: Map.get(track, :BitRate),
      channels: Map.get(track, :Channels),
      channel_positions: Map.get(track, :ChannelPositions),
      sampling_rate: Map.get(track, :SamplingRate),
      duration: Map.get(track, :Duration),
      language: Map.get(track, :Language)
    }
  end

  def valid?(%AudioTrack{} = track) do
    not is_nil(Map.get(track, :CodecID)) or not is_nil(Map.get(track, :Format))
  end

  def codec_id(%AudioTrack{} = track), do: Map.get(track, :CodecID)

  def to_legacy_map(%AudioTrack{} = track) do
    track
    |> Map.from_struct()
    |> Map.put("@type", "Audio")
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end
end

defimpl Reencodarr.Media.TrackProtocol, for: TextTrack do
  def track_type(_), do: :text

  def extract_metadata(%TextTrack{} = track) do
    %{
      format: Map.get(track, :Format),
      language: Map.get(track, :Language),
      title: Map.get(track, :Title),
      default: Map.get(track, :Default),
      forced: Map.get(track, :Forced),
      duration: Map.get(track, :Duration)
    }
  end

  def valid?(%TextTrack{} = track) do
    not is_nil(Map.get(track, :Format)) or not is_nil(Map.get(track, :Language))
  end

  def codec_id(%TextTrack{} = track), do: Map.get(track, :CodecID)

  def to_legacy_map(%TextTrack{} = track) do
    track
    |> Map.from_struct()
    |> Map.put("@type", "Text")
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end
end

# Fallback implementation for generic Track
defimpl Reencodarr.Media.TrackProtocol, for: Track do
  def track_type(_), do: :unknown
  def extract_metadata(%Track{} = track), do: Map.from_struct(track)
  def valid?(_), do: false
  def codec_id(_), do: nil
  def to_legacy_map(%Track{} = track), do: Map.from_struct(track)
end
