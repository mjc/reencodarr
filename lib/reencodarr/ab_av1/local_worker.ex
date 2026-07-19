defmodule Reencodarr.AbAv1.LocalWorker do
  @moduledoc """
  Supervises the long-lived local `ab-av1 worker` process.
  """

  use GenServer

  require Logger

  alias Reencodarr.AbAv1.{Helper, WorkerConfig, WorkerProtocol}
  alias Reencodarr.Media

  @type status :: %{
          running: boolean(),
          executable: String.t(),
          connect_url: String.t(),
          worker_id: String.t(),
          version: String.t(),
          os_pid: non_neg_integer() | nil,
          last_exit_status: non_neg_integer() | nil,
          restart_count: non_neg_integer()
        }

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: 10_000
    }
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    config =
      opts
      |> Keyword.get_lazy(:config, &WorkerConfig.local_worker_config!/0)
      |> Map.put_new(:extra_args, [])
      |> Map.put_new(:restart_base_ms, 1_000)
      |> Map.put_new(:restart_max_ms, 30_000)

    :ok = Media.reset_orphaned_crf_searching()

    with {:ok, executable} <- find_executable(config.executable),
         {:ok, version} <- executable_version(executable),
         {:ok, port} <- open_worker(executable, config) do
      {:ok,
       %{
         config: %{config | executable: executable},
         port: port,
         version: version,
         restart_count: 0,
         last_exit_status: nil
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    reply = %{
      running: is_port(state.port) and not is_nil(Port.info(state.port)),
      executable: state.config.executable,
      connect_url: state.config.connect_url,
      worker_id: state.config.worker_id,
      version: state.version,
      os_pid: os_pid(state.port),
      last_exit_status: state.last_exit_status,
      restart_count: state.restart_count
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    Logger.info("ab-av1 worker: #{redact(line, state.config.token)}")
    {:noreply, state}
  end

  def handle_info({port, {:data, {:noeol, line}}}, %{port: port} = state) do
    Logger.debug("ab-av1 worker: #{redact(line, state.config.token)}")
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    delay = restart_delay(state)

    Logger.warning("ab-av1 worker exited with status #{status}; restarting in #{delay}ms")

    Process.send_after(self(), :restart_worker, delay)

    {:noreply,
     %{state | port: nil, last_exit_status: status, restart_count: state.restart_count + 1}}
  end

  def handle_info(:restart_worker, %{port: nil} = state) do
    case open_worker(state.config.executable, state.config) do
      {:ok, port} ->
        {:noreply, %{state | port: port}}

      {:error, reason} ->
        delay = restart_delay(state)

        Logger.error(
          "could not restart ab-av1 worker: #{inspect(reason)}; retrying in #{delay}ms"
        )

        Process.send_after(self(), :restart_worker, delay)
        {:noreply, %{state | restart_count: state.restart_count + 1}}
    end
  end

  def handle_info({:EXIT, port, _reason}, state) when is_port(port), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    stop_port_process(port)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp find_executable(executable) do
    case System.find_executable(executable) do
      nil -> {:error, {:worker_executable_not_found, executable}}
      path -> {:ok, path}
    end
  end

  defp executable_version(executable) do
    case System.cmd(executable, ["--version"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:worker_version_check_failed, status, String.trim(output)}}
    end
  end

  defp open_worker(executable, config) do
    work_dir = Map.get(config, :work_dir, Helper.temp_dir())
    :ok = File.mkdir_p(work_dir)

    args =
      [
        "worker",
        "--connect",
        config.connect_url,
        "--token",
        config.token,
        "--worker-id",
        config.worker_id,
        "--protocol-version",
        Integer.to_string(hd(WorkerProtocol.supported_protocol_versions()))
      ] ++ config.extra_args

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        {:line, 8_192},
        :use_stdio,
        :stderr_to_stdout,
        {:cd, work_dir},
        args: args
      ])

    Logger.info("started ab-av1 worker #{config.worker_id} connecting to #{config.connect_url}")

    {:ok, port}
  rescue
    error -> {:error, {:worker_start_failed, Exception.message(error)}}
  end

  defp restart_delay(state) do
    multiplier = Integer.pow(2, min(state.restart_count, 10))
    min(state.config.restart_base_ms * multiplier, state.config.restart_max_ms)
  end

  defp os_pid(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end

  defp os_pid(_port), do: nil

  defp stop_port_process(port) do
    if pid = os_pid(port) do
      stop_process_group(pid)
    end

    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp stop_process_group(pid) do
    _ = signal_process(pid, "TERM")

    if !wait_for_process_exit(pid, 20) do
      _ = signal_process(pid, "KILL")
    end
  end

  defp wait_for_process_exit(_pid, 0), do: false

  defp wait_for_process_exit(pid, attempts) do
    if process_group_alive?(pid) do
      Process.sleep(50)
      wait_for_process_exit(pid, attempts - 1)
    else
      true
    end
  end

  defp process_group_alive?(pid), do: signal_process(pid, "0") == :ok

  defp signal_process(pid, signal) do
    with executable when is_binary(executable) <- System.find_executable("kill"),
         {_output, 0} <-
           System.cmd(executable, ["-#{signal}", "--", "-#{pid}"], stderr_to_stdout: true) do
      :ok
    else
      _ -> :error
    end
  end

  defp redact(line, token), do: String.replace(line, token, "[REDACTED]")
end
