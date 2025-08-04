defmodule Reencodarr.AbAv1 do
  @moduledoc """
  Supervisor for AV1 CRF search and encode workers.

  Provides functions to queue CRF searches and encodes, and to check queue lengths.
  """

  use Supervisor
  require Logger

  alias Reencodarr.Media

  ## Public API

  @doc """
  Starts the `#{inspect(__MODULE__)}` supervisor.
  """
  @spec start_link(any()) :: Supervisor.on_start()
  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Returns the message queue lengths for the CRF search and encode GenServers.

      iex> #{inspect(__MODULE__)}.queue_length()
      %{crf_searches: 0, encodes: 0}
  """
  @spec queue_length() :: %{crf_searches: non_neg_integer(), encodes: non_neg_integer()}
  def queue_length do
    %{
      crf_searches: queue_length_for(Reencodarr.AbAv1.CrfSearch),
      encodes: queue_length_for(Reencodarr.AbAv1.Encode)
    }
  end

  @doc """
  Queues a CRF search for the given video and VMAF percent (default: 95).

  ## Parameters

    - `video`: a `%Media.Video{}` struct
    - `vmaf_percent`: integer (default: 95)
  """
  @spec crf_search(Media.Video.t(), integer()) :: :ok
  def crf_search(video, vmaf_percent \\ 95) do
    GenServer.cast(Reencodarr.AbAv1.CrfSearch, {:crf_search, video, vmaf_percent})
  end

  @doc """
  Queues an encode for the given VMAF result.

  ## Parameters

    - `vmaf`: a `%Media.Vmaf{}` struct
  """
  @spec encode(Media.Vmaf.t()) :: :ok
  def encode(vmaf) do
    GenServer.cast(Reencodarr.AbAv1.Encode, {:encode, vmaf})
  end

  ## Supervisor Callbacks

  @doc false
  def init(:ok) do
    children = [
      Reencodarr.AbAv1.CrfSearch,
      Reencodarr.AbAv1.Encode
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  ## Private Helpers

  @doc false
  defp queue_length_for(server) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) ->
        case Process.info(pid, :message_queue_len) do
          {:message_queue_len, len} -> len
          _ -> 0
        end

      _ ->
        0
    end
  end
end
