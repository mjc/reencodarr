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
       video: :none,
       vmaf: :none
     }}
  end

  @spec encode(Media.Vmaf.t()) :: :ok
  def encode(vmaf) do
    Logger.info("Starting encode for VMAF: #{inspect(vmaf)}")
    GenServer.cast(__MODULE__, {:encode, vmaf})
  end

  @impl true
  def handle_call(:port_status, _from, %{port: port} = state) do
    status = if port == :none, do: :not_running, else: :running
    {:reply, status, state}
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
      ] ++ Helper.remove_args(vmaf.params, ["--min-vmaf", "--temp-dir", "crf-search"])

    Logger.info("Starting encode with args: #{inspect(args)}")

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
  def handle_cast({:encode, %Media.Vmaf{} = _vmaf}, %{port: port} = state) when port != :none do
    Logger.info("Encoding is already in progress, skipping new encode request.")
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, data}}}, %{port: port} = state) do
    Helper.update_encoding_progress(data, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, {:noeol, message}}}, %{port: port} = state) do
    Logger.error("Received partial message: #{message}")
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {port, {:exit_status, exit_code}},
        %{port: port, vmaf: _vmaf} = state
      ) do
    result =
      case exit_code do
        0 -> {:ok, :success}
        1 -> {:ok, :success}
        _ -> {:error, exit_code}
      end

    Logger.debug("Exit status: #{inspect(result)}")

    new_state = %{state | port: :none, video: :none, vmaf: :none}
    {:noreply, new_state}
  end
end
