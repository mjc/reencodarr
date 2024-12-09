defmodule Reencodarr.AbAv1 do
  use Supervisor

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
    crf_searches = GenServer.call(Reencodarr.AbAv1.CrfSearch, :queue_length)
    encodes = GenServer.call(Reencodarr.AbAv1.Encode, :queue_length)
    %{crf_searches: crf_searches, encodes: encodes}
  end

  @spec crf_search(Media.Video.t(), integer()) :: :ok
  def crf_search(video, vmaf_percent \\ 95) do
    GenServer.cast(Reencodarr.AbAv1.CrfSearch, {:crf_search, video, vmaf_percent})
  end

  @spec encode(Media.Vmaf.t(), atom()) :: :ok
  def encode(vmaf, position \\ :end) do
    GenServer.cast(Reencodarr.AbAv1.Encode, {:encode, vmaf, position})
  end
end
