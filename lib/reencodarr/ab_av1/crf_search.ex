defmodule Reencodarr.AbAv1.CrfSearch do
  use GenServer
  alias Reencodarr.{Media}
  alias Reencodarr.AbAv1.Helper
  require Logger

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok),
    do:
      {:ok,
       %{
         port: :none,
         queue: :queue.new(),
         crf_searches: 0
       }}

  @spec crf_search(Media.Video.t(), integer()) :: :ok
  def crf_search(video, vmaf_percent \\ 95) do
    GenServer.cast(__MODULE__, {:crf_search, video, vmaf_percent})
  end

  @impl true
  def handle_call(:queue_length, _from, %{crf_searches: crf_searches} = state) do
    {:reply, crf_searches, state}
  end

  @impl true
  def handle_cast({:crf_search, video, vmaf_percent}, %{port: :none} = state) do
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "scanning", %{
      action: "scanning:start",
      video: video
    })

    args = ["crf-search"] ++ Helper.build_args(video.path, vmaf_percent, video)

    new_crf_searches = max(state.crf_searches - 1, 0)

    new_state = %{
      state
      | port: Helper.open_port(args),
        video: video,
        args: args,
        mode: :crf_search,
        crf_searches: new_crf_searches
    }

    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "scanning", %{
      action: "queue:update",
      crf_searches: new_state.crf_searches
    })

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:crf_search, video, vmaf_percent}, %{port: port} = state) when port != :none do
    Logger.debug("Queueing crf search for video #{video.id}")
    new_queue = :queue.in({:crf_search, video, vmaf_percent}, state.queue)
    new_state = %{state | queue: new_queue, crf_searches: state.crf_searches + 1}

    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "scanning", %{
      action: "queue:update",
      crf_searches: new_state.crf_searches
    })

    {:noreply, new_state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, data}}}, %{port: port, mode: :crf_search} = state) do
    vmafs =
      data
      |> String.split("\n", trim: true)
      |> Helper.parse_crf_search()
      |> Helper.attach_params(state.video, state.args)

    Enum.each(vmafs, fn vmaf ->
      Logger.debug("Parsed output: #{inspect(vmaf)}")

      Phoenix.PubSub.broadcast(Reencodarr.PubSub, "scanning", %{
        action: "scanning:progress",
        vmaf: Map.put(vmaf, "target_vmaf", state.args |> Enum.at(4))
      })
    end)

    {:noreply, %{state | last_vmaf: List.last(vmafs)}}
  end

  @impl true
  def handle_info(
        {port, {:exit_status, exit_code}},
        %{port: port, queue: queue, last_vmaf: last_vmaf, mode: :crf_search} = state
      ) do
    case {exit_code, last_vmaf} do
      {0, last_vmaf} ->
        Phoenix.PubSub.broadcast(Reencodarr.PubSub, "scanning", %{
          action: "scanning:finished",
          vmaf:
            Map.put(last_vmaf, "chosen", true) |> Map.put("target_vmaf", state.args |> Enum.at(3))
        })

      {_, _} ->
        Logger.error("CRF search failed with exit code #{exit_code}")

        Phoenix.PubSub.broadcast(Reencodarr.PubSub, "scanning", %{
          action: "scanning:failed",
          reason: "No suitable CRF found"
        })
    end

    new_state = Helper.dequeue(queue, state)
    {:noreply, new_state}
  end
end
