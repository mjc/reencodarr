defmodule Reencodarr.AbAv1.WorkerProtocol do
  @moduledoc """
  Server-side helpers for the ab-av1 worker websocket protocol.
  """

  @crf_search_topic "workers:crf_search"
  @supported_protocol_versions [1]

  def crf_search_topic, do: @crf_search_topic

  def supported_protocol_versions, do: @supported_protocol_versions

  def valid_topic?(@crf_search_topic), do: true
  def valid_topic?(_topic), do: false

  def supported_protocol_version?(protocol_version),
    do: protocol_version in @supported_protocol_versions

  def parse_announcement(%{
        "worker_id" => worker_id,
        "protocol_version" => protocol_version,
        "version" => version,
        "capabilities" => capabilities
      })
      when is_binary(worker_id) and is_integer(protocol_version) and is_binary(version) and
             is_map(capabilities) do
    {:ok,
     %{
       worker_id: worker_id,
       protocol_version: protocol_version,
       version: version,
       capabilities: capabilities
     }}
  end

  def parse_announcement(_payload), do: {:error, :invalid_announcement}

  def accepted(protocol_version), do: %{accepted: true, protocol_version: protocol_version}

  def no_work, do: %{status: "no_work"}

  def heartbeat_ack(last_seen_at),
    do: %{accepted: true, last_seen_at: DateTime.to_iso8601(last_seen_at)}

  def error(:duplicate_worker_id), do: %{reason: "duplicate_worker_id"}

  def error(:invalid_announcement), do: %{reason: "invalid_announcement"}

  def error(:unsupported_protocol_version) do
    %{
      reason: "unsupported_protocol_version",
      supported_protocol_versions: @supported_protocol_versions
    }
  end

  def error(:unknown_worker_session), do: %{reason: "unknown_worker_session"}
  def error(:unauthorized), do: %{reason: "unauthorized"}
end
