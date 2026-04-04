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

  def queue(fun) when is_function(fun, 0) do
    process(fun)
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

  def reconcile_waiting_bad_file_issues({:ok, {:ok, video}}, service_type) do
    Reencodarr.Media.reconcile_replacement_video(video, service_type)
  end

  def reconcile_waiting_bad_file_issues({:ok, video}, service_type) do
    Reencodarr.Media.reconcile_replacement_video(video, service_type)
  end

  def reconcile_waiting_bad_file_issues(other_result, _service_type) do
    other_result
  end

  @impl true
  def init(_opts) do
    {:ok, []}
  end

  @impl true
  def handle_cast({:process, fun}, []) do
    # Process immediately if queue is empty
    execute_task(fun)

    {:noreply, []}
  end

  @impl true
  def handle_cast({:process, fun}, state) do
    # Queue if already processing
    {:noreply, [fun | state]}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, [fun | rest]) do
    # Process next item when current one completes
    execute_task(fun)
    {:noreply, rest}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, []) do
    # No more items to process
    {:noreply, []}
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
