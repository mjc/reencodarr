defmodule Reencodarr.DbWriter do
  @moduledoc """
  Serializes runtime SQLite mutations through a single in-process writer.

  Reads stay concurrent on the normal repo pool. Runtime writes should route
  through this module so only one process is mutating SQLite at a time.
  """

  use GenServer
  require Logger

  alias Reencodarr.Core.Retry
  alias Reencodarr.Repo

  @inline_envs [:test]
  @default_call_timeout 60_000
  @default_max_attempts 3
  @default_backoff_ms 25

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec run((-> result), keyword()) :: result when result: var
  def run(fun, opts \\ []) when is_function(fun, 0) do
    if inline_mode?(opts) or in_writer?() do
      execute_inline(fun, opts)
    else
      __MODULE__
      |> GenServer.call(
        {:run, fun, opts},
        Keyword.get(opts, :writer_timeout, @default_call_timeout)
      )
      |> unwrap_result()
    end
  end

  @spec transaction((-> result), keyword()) :: {:ok, result} | {:error, term()} when result: var
  def transaction(fun, opts \\ []) when is_function(fun, 0) do
    run(fn -> Repo.transaction(fun) end, opts)
  end

  @spec enqueue((-> any()), keyword()) :: :ok
  def enqueue(fun, opts \\ []) when is_function(fun, 0) do
    if inline_mode?(opts) or in_writer?() do
      execute_enqueue(fun, opts)
      :ok
    else
      GenServer.cast(__MODULE__, {:enqueue, fun, opts})
    end
  end

  @spec in_writer?() :: boolean()
  def in_writer?, do: Process.get(:db_writer_active, false) == true

  @impl true
  def init(_opts) do
    {:ok, :ok}
  end

  @impl true
  def handle_call({:run, fun, opts}, _from, state) do
    {:reply, execute(fun, opts), state}
  end

  @impl true
  def handle_cast({:enqueue, fun, opts}, state) do
    execute_enqueue(fun, opts)

    {:noreply, state}
  end

  defp inline_mode?(opts) do
    Keyword.get(opts, :inline?, default_inline_mode?())
  end

  defp default_inline_mode? do
    Application.get_env(:reencodarr, :env) in @inline_envs
  end

  defp execute_inline(fun, opts) do
    execute(fun, opts)
    |> unwrap_result()
  end

  defp execute_enqueue(fun, opts) do
    case execute(fun, opts) do
      {:ok, _result} ->
        :ok

      {:raised, kind, reason, stacktrace} ->
        log_async_failure(kind, reason, stacktrace, opts)
    end
  end

  defp execute(fun, opts) do
    retry_opts = [
      max_attempts: Keyword.get(opts, :max_attempts, @default_max_attempts),
      base_backoff_ms: Keyword.get(opts, :base_backoff_ms, @default_backoff_ms),
      label: Keyword.get(opts, :label)
    ]

    previous = Process.get(:db_writer_active)
    Process.put(:db_writer_active, true)

    try do
      {:ok, Retry.retry_on_db_busy(fun, retry_opts)}
    rescue
      error ->
        {:raised, :error, error, __STACKTRACE__}
    catch
      kind, reason ->
        {:raised, kind, reason, __STACKTRACE__}
    after
      if previous == nil do
        Process.delete(:db_writer_active)
      else
        Process.put(:db_writer_active, previous)
      end
    end
  end

  defp unwrap_result({:ok, value}), do: value

  defp unwrap_result({:raised, kind, reason, stacktrace}) do
    :erlang.raise(kind, reason, stacktrace)
  end

  defp log_async_failure(kind, reason, stacktrace, opts) do
    label = Keyword.get(opts, :label, :db_writer)

    Logger.error("""
    DbWriter async task failed for #{inspect(label)}
    #{Exception.format(kind, reason, stacktrace)}
    """)
  end
end
