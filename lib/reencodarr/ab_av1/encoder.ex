defmodule Reencodarr.AbAv1.Encoder do
  @moduledoc """
  Named port-holder for ab-av1 encode operations.

  This GenServer owns the OS port for a single encode job and is designed to
  survive restarts of `AbAv1.Encode`. It buffers output lines and forwards them
  to a subscriber PID. When `AbAv1.Encode` restarts, it re-subscribes here to
  receive buffered output and continue tracking the in-flight encode.

  Started on-demand (not in the supervisor tree directly) under
  `Reencodarr.PortSupervisor` with `:temporary` restart policy so it is never
  automatically restarted.
  """

  use GenServer

  alias Reencodarr.AbAv1.Helper

  require Logger

  @max_buffered_lines 1024

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec child_spec({[binary()], map()}) :: Supervisor.child_spec()
  def child_spec({args, metadata}) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [args, metadata]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc """
  Called by DynamicSupervisor to start and link to this process.
  Opens the port immediately inside `init/1`.
  """
  @spec start_link([binary()], map()) :: GenServer.on_start()
  def start_link(args, metadata) do
    GenServer.start_link(__MODULE__, {args, metadata}, name: __MODULE__)
  end

  @doc "Start the port holder under PortSupervisor. Called by AbAv1.Encode."
  @spec start([binary()], map()) :: {:ok, pid()} | {:error, term()}
  def start(args, metadata) do
    DynamicSupervisor.start_child(
      Reencodarr.PortSupervisor,
      {__MODULE__, {args, metadata}}
    )
  end

  @doc "Check whether an encode is currently in flight."
  @spec running?() :: boolean()
  def running? do
    case GenServer.whereis(__MODULE__) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  @doc """
  Subscribe `pid` to receive port output.

  All buffered lines are replayed to `pid` immediately via `send/2` (in
  chronological order). New lines are forwarded as they arrive.
  Returns `{:ok, buffered_count}`.
  """
  @spec subscribe(pid()) :: {:ok, non_neg_integer()} | {:error, :not_running}
  def subscribe(pid) do
    case GenServer.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      server -> GenServer.call(server, {:subscribe, pid})
    end
  end

  @doc "Return the encode metadata stored at start time (vmaf, output_file, encode_args)."
  @spec get_metadata() :: {:ok, map()} | {:error, :not_running}
  def get_metadata do
    case GenServer.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      server -> GenServer.call(server, :get_metadata)
    end
  end

  @doc "Return the OS PID of the ab-av1/ffmpeg process."
  @spec get_os_pid() :: integer() | nil | {:error, :not_running}
  def get_os_pid do
    case GenServer.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      server -> GenServer.call(server, :get_os_pid)
    end
  end

  @doc """
  Kill the running OS process group and stop this GenServer.

  Used by `AbAv1.Encode.reset_if_stuck/0` and the HealthCheck fallback.
  """
  @spec kill() :: :ok
  def kill do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      server -> GenServer.call(server, :kill, 5_000)
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init({args, metadata}) do
    Process.flag(:trap_exit, true)

    case Helper.open_port(args) do
      {:ok, port} ->
        os_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, pid} -> pid
            _ -> nil
          end

        Logger.info("Encoder: port opened (OS PID: #{os_pid})")

        {:ok,
         %{
           port: port,
           os_pid: os_pid,
           metadata: metadata,
           output_lines: [],
           subscriber: nil
         }}

      {:error, reason} ->
        Logger.error("Encoder: failed to open port: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    # Replay buffered lines in chronological order (stored prepended, so reverse)
    buffered = Enum.reverse(state.output_lines)
    count = length(buffered)
    Enum.each(buffered, fn msg -> send(pid, msg) end)
    Logger.debug("Encoder: subscribed #{inspect(pid)}, replayed #{count} lines")
    {:reply, {:ok, count}, %{state | subscriber: pid}}
  end

  @impl true
  def handle_call(:get_metadata, _from, state) do
    {:reply, {:ok, state.metadata}, state}
  end

  @impl true
  def handle_call(:get_os_pid, _from, state) do
    {:reply, state.os_pid, state}
  end

  @impl true
  def handle_call(:kill, _from, state) do
    Logger.info("Encoder: kill() called, terminating OS process #{state.os_pid}")
    Helper.kill_process_group(state.os_pid)
    Helper.close_port(state.port)
    {:stop, :normal, :ok, %{state | os_pid: nil, port: :none}}
  end

  # eol data line from port
  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    msg = {__MODULE__, {:line, line}}

    new_lines =
      if length(state.output_lines) < @max_buffered_lines do
        [msg | state.output_lines]
      else
        [msg | Enum.take(state.output_lines, @max_buffered_lines - 1)]
      end

    if state.subscriber, do: send(state.subscriber, msg)
    {:noreply, %{state | output_lines: new_lines}}
  end

  # noeol partial chunk — forward but do not buffer (partial lines aren't useful for replay)
  @impl true
  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    msg = {__MODULE__, {:partial, chunk}}
    if state.subscriber, do: send(state.subscriber, msg)
    {:noreply, state}
  end

  # Port exited with a status code
  @impl true
  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.info("Encoder: port exited with status #{code}")
    msg = {__MODULE__, {:exit_status, code}}
    if state.subscriber, do: send(state.subscriber, msg)
    {:stop, :normal, state}
  end

  # Port closed / died without exit_status (safety net)
  @impl true
  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.error("Encoder: port died unexpectedly: #{inspect(reason)}")
    msg = {__MODULE__, {:exit_status, {:port_died, reason}}}
    if state.subscriber, do: send(state.subscriber, msg)
    {:stop, :normal, state}
  end

  # Normal port EXIT after exit_status already handled — ignore
  @impl true
  def handle_info({:EXIT, _port, :normal}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("Encoder: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # :normal  → port exited naturally or kill() already cleaned up
  # :shutdown → BEAM shutting down while encode is in progress → kill OS process
  # other    → crash → kill OS process to avoid orphan
  @impl true
  def terminate(:normal, _state), do: :ok

  def terminate(reason, state) do
    Logger.warning("Encoder: terminating (#{inspect(reason)}), killing OS process")
    Helper.kill_process_group(state.os_pid)
    Helper.close_port(state.port)
    :ok
  end
end
