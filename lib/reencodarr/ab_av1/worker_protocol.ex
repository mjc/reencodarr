defmodule Reencodarr.AbAv1.WorkerProtocol do
  @moduledoc """
  Server-side helpers for the ab-av1 worker websocket protocol.
  """

  alias Reencodarr.Media.Video

  @crf_search_topic "workers:crf_search"
  @supported_protocol_versions [1]

  defmodule Announcement do
    @moduledoc false

    @enforce_keys [:worker_id, :protocol_version, :version, :capabilities]
    defstruct [:worker_id, :protocol_version, :version, :capabilities]

    @type t :: %__MODULE__{
            worker_id: String.t(),
            protocol_version: pos_integer(),
            version: String.t(),
            capabilities: map()
          }
  end

  @spec crf_search_topic() :: String.t()
  def crf_search_topic, do: @crf_search_topic

  @spec supported_protocol_versions() :: [pos_integer()]
  def supported_protocol_versions, do: @supported_protocol_versions

  @spec valid_topic?(String.t()) :: boolean()
  def valid_topic?(@crf_search_topic), do: true
  def valid_topic?(_topic), do: false

  @spec supported_protocol_version?(integer()) :: boolean()
  def supported_protocol_version?(protocol_version),
    do: protocol_version in @supported_protocol_versions

  @spec parse_announcement(map()) :: {:ok, Announcement.t()} | {:error, :invalid_announcement}
  def parse_announcement(%{
        "worker_id" => worker_id,
        "protocol_version" => protocol_version,
        "version" => version,
        "capabilities" => capabilities
      })
      when is_binary(worker_id) and is_integer(protocol_version) and is_binary(version) and
             is_map(capabilities) do
    {:ok,
     %Announcement{
       worker_id: worker_id,
       protocol_version: protocol_version,
       version: version,
       capabilities: capabilities
     }}
  end

  def parse_announcement(_payload), do: {:error, :invalid_announcement}

  @spec accepted(pos_integer()) :: map()
  def accepted(protocol_version), do: %{accepted: true, protocol_version: protocol_version}

  @spec no_work() :: map()
  def no_work, do: %{status: "no_work"}

  @spec work_assigned(Video.t(), number()) :: map()
  def work_assigned(%Video{id: video_id, path: path, size: size}, target_vmaf)
      when is_integer(video_id) and is_binary(path) do
    %{
      status: "job_assigned",
      job_id: Integer.to_string(video_id),
      video_id: video_id,
      source_name: Path.basename(path),
      size_bytes: size || 0,
      chunk_size_bytes: 1_048_576,
      target_vmaf: target_vmaf
    }
  end

  @spec heartbeat_ack(DateTime.t()) :: map()
  def heartbeat_ack(last_seen_at),
    do: %{accepted: true, last_seen_at: DateTime.to_iso8601(last_seen_at)}

  @spec error(
          :duplicate_worker_id
          | :invalid_announcement
          | :invalid_session_attrs
          | :unsupported_protocol_version
          | :unsupported_event
          | :unknown_worker_session
          | :unauthorized
        ) :: map()
  def error(:duplicate_worker_id), do: %{reason: "duplicate_worker_id"}

  def error(:invalid_announcement), do: %{reason: "invalid_announcement"}
  def error(:invalid_session_attrs), do: %{reason: "invalid_session_attrs"}

  def error(:unsupported_protocol_version) do
    %{
      reason: "unsupported_protocol_version",
      supported_protocol_versions: @supported_protocol_versions
    }
  end

  def error(:unsupported_event), do: %{reason: "unsupported_event"}
  def error(:unknown_worker_session), do: %{reason: "unknown_worker_session"}
  def error(:unauthorized), do: %{reason: "unauthorized"}
end
