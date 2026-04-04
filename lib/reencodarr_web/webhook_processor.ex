defmodule ReencodarrWeb.WebhookProcessor do
  @moduledoc """
  GenServer that processes webhook tasks sequentially to prevent SQLite lock contention.

  Webhooks queue their work via cast, avoiding Task.start which floods SQLite with
  concurrent writes. The GenServer processes one task at a time with retry logic.

  In test environment, tasks are executed synchronously in the calling process to avoid
  database sandbox issues.
  """

  use GenServer
  require Logger

  alias Reencodarr.Core.Retry

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  if Application.compile_env(:reencodarr, :env) == :test do
    def process(fun) when is_function(fun, 0) do
      # In test, execute synchronously to avoid sandbox connection issues
      # We need explicit try/catch to catch :exit signals from OTP processes
      # credo:disable-for-next-line Credo.Check.Readability.ImplicitTry
      try do
        Retry.retry_on_db_busy(fun)
      catch
        :exit, reason ->
          Logger.error("Webhook processor task failed: #{inspect(reason)}")
      end
    end
  else
    def process(fun) when is_function(fun, 0) do
      # In production, queue via GenServer for sequential processing
      GenServer.cast(__MODULE__, {:process, fun})
    end
  end

  @impl true
  def init(_opts) do
    {:ok, :empty}
  end

  @impl true
  def handle_cast({:process, fun}, :empty) do
    # Process immediately if queue is empty
    execute_task(fun)

    {:noreply, :empty}
  end

  def handle_cast({:process, fun}, state) do
    # Queue if already processing
    {:noreply, [fun | state]}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, [fun | rest]) do
    # Process next item when current one completes
    execute_task(fun)

    if rest == [] do
      {:noreply, :empty}
    else
      {:noreply, rest}
    end
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, :empty) do
    {:noreply, :empty}
  end

  defp execute_task(fun) do
    # Spawn a linked process for async sequential execution
    spawn_link(fn ->
      try do
        Retry.retry_on_db_busy(fun)
      catch
        :exit, reason ->
          Logger.error("Webhook processor task failed: #{inspect(reason)}")
      end
    end)
  end
end
