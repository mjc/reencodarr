defmodule Reencodarr.AbAv1.WorkerProtocol do
  @moduledoc """
  Server-side helpers for the ab-av1 worker websocket protocol.
  """

  @crf_search_topic "workers:crf_search"

  def crf_search_topic, do: @crf_search_topic

  def valid_topic?(@crf_search_topic), do: true
  def valid_topic?(_topic), do: false

  def parse_announcement(%{
        "worker_id" => worker_id,
        "version" => version,
        "capabilities" => capabilities
      })
      when is_binary(worker_id) and is_binary(version) and is_map(capabilities) do
    {:ok, %{worker_id: worker_id, version: version, capabilities: capabilities}}
  end

  def parse_announcement(_payload), do: {:error, :invalid_announcement}

  def accepted, do: %{accepted: true}

  def no_work, do: %{status: "no_work"}

  def error(:invalid_announcement), do: %{reason: "invalid_announcement"}
  def error(:unauthorized), do: %{reason: "unauthorized"}
end
