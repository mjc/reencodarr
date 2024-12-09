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
         args: [],
         mode: :none,
         video: :none,
         last_vmaf: :none
       }}

  @spec crf_search(Media.Video.t(), integer()) :: :ok
  def crf_search(video, vmaf_percent \\ 95) do
    GenServer.cast(__MODULE__, {:crf_search, video, vmaf_percent})
  end

  @impl true
  def handle_call(:queue_length, _from, %{queue: queue} = state) do
    {:reply, :queue.len(queue), state}
  end

  @impl true
  def handle_cast({:crf_search, video, vmaf_percent}, state) do
    new_state =
      case state.port do
        :none ->
          Phoenix.PubSub.broadcast(Reencodarr.PubSub, "scanning", %{
            action: "scanning:start",
            video: video
          })

          args = ["crf-search"] ++ Helper.build_args(video.path, vmaf_percent, video)

          %{
            state
            | port: Helper.open_port(args),
              video: video,
              args: args,
              mode: :crf_search,
              last_vmaf: :none
          }

        _ ->
          Logger.debug("Queueing crf search for video #{video.id}")
          new_queue = :queue.in({:crf_search, video, vmaf_percent}, state.queue)
          %{state | queue: new_queue}
      end

    broadcast_queue_update(new_state.queue)
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

    new_queue = Helper.dequeue_and_broadcast(queue, __MODULE__, :crf_search)
    new_state = %{state | port: :none, queue: new_queue, last_vmaf: :none, mode: :none}
    {:noreply, new_state}
  end

  defp broadcast_queue_update(queue) do
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "scanning", %{
      action: "queue:update",
      crf_searches: :queue.len(queue)
    })
  end
end
