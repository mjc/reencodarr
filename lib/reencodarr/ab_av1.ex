defmodule Reencodarr.AbAv1 do
  use Supervisor

  require Logger

  alias Reencodarr.Media

  @spec start_link(any()) :: Supervisor.on_start()
  def start_link(_opts), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    children = [
      {Reencodarr.AbAv1.CrfSearch, []},
      {Reencodarr.AbAv1.Encode, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @spec queue_length() :: %{crf_searches: integer(), encodes: integer()}
  def queue_length do
    crf_searches =
      case GenServer.whereis(Reencodarr.AbAv1.CrfSearch) do
        nil -> 0
        pid -> Process.info(pid, :message_queue_len) |> elem(1)
      end

    encodes =
      case GenServer.whereis(Reencodarr.AbAv1.Encode) do
        nil -> 0
        pid -> Process.info(pid, :message_queue_len) |> elem(1)
      end

    %{crf_searches: crf_searches, encodes: encodes}
  end

  @spec crf_search(Media.Video.t(), integer()) :: :ok
  def crf_search(video, vmaf_percent \\ 95) do
    GenServer.cast(Reencodarr.AbAv1.CrfSearch, {:crf_search, video, vmaf_percent})
  end

  @spec encode(Media.Vmaf.t()) :: :ok
  def encode(vmaf) do
    Logger.debug("Starting encode for VMAF: #{inspect(vmaf)}")
    GenServer.cast(Reencodarr.AbAv1.Encode, {:encode, vmaf})
  end
end
