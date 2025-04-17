@moduledoc """
Supervisor for AV1 CRF search and encode workers.
Provides functions to queue CRF searches and encodes, and to check queue lengths.
"""
defmodule Reencodarr.AbAv1 do
  use Supervisor

  require Logger

  alias Reencodarr.Media

  @doc """
  Starts the AbAv1 supervisor.
  """
  @spec start_link(any()) :: Supervisor.on_start()
  def start_link(_opts), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    children = [
      Reencodarr.AbAv1.CrfSearch,
      Reencodarr.AbAv1.Encode
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns the message queue lengths for the CRF search and encode GenServers.
  """
  @spec queue_length() :: %{crf_searches: non_neg_integer(), encodes: non_neg_integer()}
  def queue_length do
    %{crf_searches: queue_len(Reencodarr.AbAv1.CrfSearch),
      encodes: queue_len(Reencodarr.AbAv1.Encode)}
  end

  defp queue_len(server) do
    with pid when is_pid(pid) <- GenServer.whereis(server),
         {:message_queue_len, len} <- Process.info(pid, :message_queue_len) do
      len
    else
      _ -> 0
    end
  end

  @doc """
  Queues a CRF search for the given video and VMAF percent (default: 95).
  """
  @spec crf_search(Media.Video.t(), integer()) :: :ok
  def crf_search(video, vmaf_percent \\ 95) do
    GenServer.cast(Reencodarr.AbAv1.CrfSearch, {:crf_search, video, vmaf_percent})
  end

  @doc """
  Queues an encode for the given VMAF result.
  """
  @spec encode(Media.Vmaf.t()) :: :ok
  def encode(vmaf) do
    Logger.debug("Starting encode for VMAF: #{inspect(vmaf)}")
    GenServer.cast(Reencodarr.AbAv1.Encode, {:encode, vmaf})
  end
end
