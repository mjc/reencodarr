defmodule Reencodarr.AbAv1.QueueManager do
  @moduledoc """
  Pure functions for managing AB-AV1 processing queues.

  This module contains testable pure functions that don't depend on GenServers
  or other stateful processes.
  """

  @type queue_info :: %{crf_searches: non_neg_integer(), encodes: non_neg_integer()}
  @type queue_server :: pid() | atom()

  @doc """
  Calculates queue lengths from a list of servers.

  ## Examples

      iex> servers = [
      ...>   {:crf_searches, self()},
      ...>   {:encodes, self()}
      ...> ]
      iex> result = Reencodarr.AbAv1.QueueManager.calculate_queue_lengths(servers)
      iex> is_map(result) and Map.has_key?(result, :crf_searches)
      true
  """
  @spec calculate_queue_lengths([{atom(), queue_server()}]) :: queue_info()
  def calculate_queue_lengths(servers) do
    servers
    |> Enum.reduce(%{}, fn {queue_type, server}, acc ->
      length = get_queue_length_for_server(server)
      Map.put(acc, queue_type, length)
    end)
  end

  @doc """
  Gets the message queue length for a specific server.

  Returns 0 if the server is not available or doesn't have queue info.

  ## Examples

      iex> Reencodarr.AbAv1.QueueManager.get_queue_length_for_server(self())
      0

      iex> Reencodarr.AbAv1.QueueManager.get_queue_length_for_server(:non_existent)
      0
  """
  @spec get_queue_length_for_server(queue_server()) :: non_neg_integer()
  def get_queue_length_for_server(server) when is_pid(server) do
    case Process.info(server, :message_queue_len) do
      {:message_queue_len, len} when is_integer(len) -> len
      _ -> 0
    end
  end

  def get_queue_length_for_server(server) when is_atom(server) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> get_queue_length_for_server(pid)
      _ -> 0
    end
  end

  def get_queue_length_for_server(_), do: 0

  @doc """
  Validates a CRF search request.

  ## Examples

      iex> video = %{id: 123, path: "/test.mkv"}
      iex> Reencodarr.AbAv1.QueueManager.validate_crf_search_request(video, 95)
      {:ok, {video, 95}}

      iex> Reencodarr.AbAv1.QueueManager.validate_crf_search_request(nil, 95)
      {:error, :invalid_video}

      iex> Reencodarr.AbAv1.QueueManager.validate_crf_search_request(%{id: 123}, 150)
      {:error, :invalid_vmaf_percent}
  """
  @spec validate_crf_search_request(any(), integer()) ::
          {:ok, {map(), integer()}} | {:error, atom()}
  def validate_crf_search_request(video, vmaf_percent) do
    cond do
      not is_map(video) or not Map.has_key?(video, :id) ->
        {:error, :invalid_video}

      not is_integer(vmaf_percent) or vmaf_percent < 50 or vmaf_percent > 100 ->
        {:error, :invalid_vmaf_percent}

      true ->
        {:ok, {video, vmaf_percent}}
    end
  end

  @doc """
  Validates an encode request.

  ## Examples

      iex> vmaf = %{id: 456, video_id: 123, crf: 28.0}
      iex> Reencodarr.AbAv1.QueueManager.validate_encode_request(vmaf)
      {:ok, vmaf}

      iex> Reencodarr.AbAv1.QueueManager.validate_encode_request(nil)
      {:error, :invalid_vmaf}

      iex> Reencodarr.AbAv1.QueueManager.validate_encode_request(%{id: 456})
      {:error, :missing_video_id}
  """
  @spec validate_encode_request(any()) :: {:ok, map()} | {:error, atom()}
  def validate_encode_request(vmaf) do
    cond do
      not is_map(vmaf) or not Map.has_key?(vmaf, :id) ->
        {:error, :invalid_vmaf}

      not Map.has_key?(vmaf, :video_id) ->
        {:error, :missing_video_id}

      true ->
        {:ok, vmaf}
    end
  end

  @doc """
  Builds a CRF search message tuple.

  ## Examples

      iex> video = %{id: 123, path: "/test.mkv"}
      iex> Reencodarr.AbAv1.QueueManager.build_crf_search_message(video, 95)
      {:crf_search, %{id: 123, path: "/test.mkv"}, 95}
  """
  @spec build_crf_search_message(map(), integer()) :: {:crf_search, map(), integer()}
  def build_crf_search_message(video, vmaf_percent) do
    {:crf_search, video, vmaf_percent}
  end

  @doc """
  Builds an encode message tuple.

  ## Examples

      iex> vmaf = %{id: 456, video_id: 123, crf: 28.0}
      iex> Reencodarr.AbAv1.QueueManager.build_encode_message(vmaf)
      {:encode, %{id: 456, video_id: 123, crf: 28.0}}
  """
  @spec build_encode_message(map()) :: {:encode, map()}
  def build_encode_message(vmaf) do
    {:encode, vmaf}
  end
end
