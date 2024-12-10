defmodule Reencodarr.AbAv1.Encode do
  use GenServer
  alias Reencodarr.{Media}
  alias Reencodarr.AbAv1.Helper
  require Logger

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    {:ok,
     %{
       port: :none,
       queue: :queue.new(),
       video: :none,
       vmaf: :none
     }}
  end

  @spec encode(Media.Vmaf.t(), atom()) :: :ok
  def encode(vmaf, position \\ :end) do
    GenServer.cast(__MODULE__, {:encode, vmaf, position})
  end

  @impl true
  def handle_call(:queue_length, _from, %{queue: :empty} = state) do
    {:reply, 0, state}
  end

  def handle_call(:queue_length, _from, %{queue: queue} = state) do
    {:reply, :queue.len(queue), state}
  end

  defp prepare_encode_state(vmaf, state) do
    args =
      [
        "encode",
        "--crf",
        to_string(vmaf.crf),
        "-o",
        Path.join(Helper.temp_dir(), "#{vmaf.video.id}.mkv"),
        "-i"
      ] ++ vmaf.params

    %{
      state
      | port: Helper.open_port(args),
        video: vmaf.video,
        vmaf: vmaf
    }
  end

  @impl true
  def handle_cast(
        {:encode, %Media.Vmaf{params: _params} = vmaf},
        %{port: :none} = state
      ) do
    new_state = prepare_encode_state(vmaf, state)

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:encode, vmaf}, %{port: port} = state) when port != :none do
    Logger.info("Queueing encode for video #{vmaf.video.id}")
    new_queue = :queue.in({:encode, vmaf}, state.queue)

    new_state = %{
      state
      | queue: new_queue,
        video: state.video
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:encode, vmaf, :insert_at_top}, %{port: :none} = state) do
    Logger.info("Inserting encode at top of queue for video #{vmaf.video.id}")
    new_state = prepare_encode_state(vmaf, state)

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:encode, vmaf, :insert_at_top}, %{port: port} = state) when port != :none do
    Logger.info("Inserting encode at top of queue for video #{vmaf.video.id}")
    new_queue = :queue.in_r({:encode, vmaf}, state.queue)

    new_state = %{
      state
      | queue: new_queue,
        video: state.video
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, data}}}, %{port: port} = state) do
    Helper.update_encoding_progress(data, state)
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {port, {:exit_status, exit_code}},
        %{port: port, queue: queue, vmaf: _vmaf} = state
      ) do
    result =
      case exit_code do
        0 -> {:ok, :success}
        1 -> {:ok, :success}
        _ -> {:error, exit_code}
      end

    Logger.debug("Exit status: #{inspect(result)}")

    new_queue = Helper.dequeue(queue, __MODULE__)
    new_state = %{state | port: :none, queue: new_queue, video: :none, vmaf: :none}
    {:noreply, new_state}
  end
end
