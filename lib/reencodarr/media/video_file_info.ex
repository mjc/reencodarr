defmodule Reencodarr.Media.VideoFileInfo do
  @moduledoc """
  Struct representing video file information from external services like Sonarr/Radarr.
  Used as an intermediate format before converting to MediaInfo or database records.
  """

  @type service_type :: :sonarr | :radarr

  @type t :: %__MODULE__{
          path: String.t(),
          size: integer() | nil,
          service_id: String.t(),
          service_type: service_type(),
          audio_codec: String.t() | nil,
          bitrate: integer() | nil,
          audio_channels: integer() | nil,
          video_codec: String.t() | nil,
          resolution: {integer(), integer()} | String.t(),
          video_fps: float() | nil,
          video_dynamic_range: String.t() | nil,
          video_dynamic_range_type: String.t() | nil,
          audio_stream_count: integer() | nil,
          overall_bitrate: integer() | nil,
          run_time: integer() | nil,
          subtitles: [String.t()] | nil,
          title: String.t() | nil,
          date_added: String.t() | nil
        }

  defstruct [
    :path,
    :size,
    :service_id,
    :service_type,
    :audio_codec,
    :bitrate,
    :audio_channels,
    :video_codec,
    :resolution,
    :video_fps,
    :video_dynamic_range,
    :video_dynamic_range_type,
    :audio_stream_count,
    :overall_bitrate,
    :run_time,
    :subtitles,
    :title,
    :date_added
  ]
end
