defmodule Reencodarr.AbAv1.Encode do
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
         encodes: 0,
         args: []
       }}

  @spec encode(Media.Vmaf.t(), atom()) :: :ok
  def encode(vmaf, position \\ :end) do
    GenServer.cast(__MODULE__, {:encode, vmaf, position})
  end

  @impl true
  def handle_call(:queue_length, _from, %{encodes: encodes} = state) do
    {:reply, encodes, state}
  end

  @impl true
  def handle_cast(
        {:encode, %Media.Vmaf{params: params} = vmaf},
        %{port: :none} = state
      ) do
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "encoding", %{
      action: "encoding",
      video: vmaf.video
    })

    args =
      [
        "encode",
        "--crf",
        to_string(vmaf.crf),
        "-o",
        Path.join(Helper.temp_dir(), "#{vmaf.video.id}.mkv"),
        "-i"
      ] ++ params

    new_encodes = max(state.encodes - 1, 0)

    new_state = %{
      state
      | port: Helper.open_port(args),
        video: vmaf.video,
        args: args,
        mode: :encode,
        encodes: new_encodes
    }

    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "queue", %{
      action: "queue:update",
      encodes: new_state.encodes
    })

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:encode, vmaf}, %{port: port} = state) when port != :none do
    Logger.info("Queueing encode for video #{vmaf.video.id}")
    new_queue = :queue.in({:encode, vmaf}, state.queue)
    new_state = %{state | queue: new_queue, encodes: state.encodes + 1}

    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "queue", %{
      action: "queue:update",
      encodes: new_state.encodes
    })

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:encode, vmaf, :insert_at_top}, %{port: :none} = state) do
    Logger.info("Inserting encode at top of queue for video #{vmaf.video.id}")

    args =
      [
        "encode",
        "--crf",
        to_string(vmaf.crf),
        "-o",
        Path.join(Helper.temp_dir(), "#{vmaf.video.id}.mkv"),
        "-i"
      ] ++ vmaf.params

    new_encodes = max(state.encodes - 1, 0)

    new_state = %{
      state
      | port: Helper.open_port(args),
        video: vmaf.video,
        args: args,
        mode: :encode,
        encodes: new_encodes
    }

    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "queue", %{
      action: "queue:update",
      encodes: new_state.encodes
    })

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:encode, vmaf, :insert_at_top}, %{port: port} = state) when port != :none do
    Logger.info("Inserting encode at top of queue for video #{vmaf.video.id}")
    new_queue = :queue.in_r({:encode, vmaf}, state.queue)
    new_state = %{state | queue: new_queue, encodes: state.encodes + 1}

    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "queue", %{
      action: "queue:update",
      encodes: new_state.encodes
    })

    {:noreply, new_state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, data}}}, %{port: port, mode: :encode} = state) do
    Helper.update_encoding_progress(data, state)
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {port, {:exit_status, exit_code}},
        %{port: port, queue: queue, mode: :encode, video: video, args: args} = state
      ) do
    result =
      case exit_code do
        0 -> {:ok, :success}
        1 -> {:ok, :success}
        _ -> {:error, exit_code}
      end

    Logger.debug("Exit status: #{inspect(result)}")

    output_file = Enum.at(args, Enum.find_index(args, &(&1 == "-o")) + 1)

    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "encoding", %{
      action: "encoding:complete",
      result: result,
      video: video,
      output_file: output_file
    })

    new_state = Helper.dequeue(queue, state)
    {:noreply, new_state}
  end
end
