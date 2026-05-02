defmodule Reencodarr.AbAv1.ProcessControl do
  @moduledoc """
  Tracks operator-level suspension for ab-av1 services.

  The actual OS process is suspended by the port holder. This process keeps the
  queue gate so producers do not dispatch new CRF/encode work while an operator
  suspension is in effect.
  """

  use GenServer

  alias Reencodarr.AbAv1.{CrfSearch, Encode}

  require Logger

  @services [:crf_searcher, :encoder]
  @check_interval_ms :timer.minutes(1)
  @default_auto_resume_after_ms :timer.hours(4)
  @default_auto_resume_hour 2
  @default_auto_resume_timezone "America/Denver"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec suspended?(atom()) :: boolean()
  def suspended?(service) when service in @services do
    call_or_default({:suspended?, service}, false)
  end

  @spec service_status(atom(), atom()) :: atom()
  def service_status(service, fallback) when service in @services and is_atom(fallback) do
    if suspended?(service), do: :paused, else: fallback
  end

  @spec suspend(atom()) :: :ok
  def suspend(service) when service in @services do
    cast_or_default({:suspend, service})
  end

  @spec resume(atom()) :: :ok
  def resume(service) when service in @services do
    cast_or_default({:resume, service})
  end

  @impl true
  def init(opts) do
    state = initial_state(opts)
    schedule_auto_resume_check(state.check_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call({:suspended?, service}, _from, state) do
    {:reply, get_in(state, [:services, service, :suspended?]) || false, state}
  end

  @impl true
  def handle_cast({:suspend, service}, state) do
    {:noreply, put_service_state(state, service, true, DateTime.utc_now())}
  end

  @impl true
  def handle_cast({:resume, service}, state) do
    {:noreply, put_service_state(state, service, false, nil)}
  end

  if Mix.env() == :test do
    @impl true
    def handle_cast({:force_suspend_at, service, suspended_at}, state) do
      {:noreply, put_service_state(state, service, true, suspended_at)}
    end
  end

  @impl true
  def handle_info(:auto_resume_check, state) do
    schedule_auto_resume_check(state.check_interval_ms)
    {:noreply, maybe_auto_resume(state)}
  end

  defp initial_state(opts) do
    app_config = Application.get_env(:reencodarr, __MODULE__, [])
    config = Keyword.merge(app_config, opts)

    %{
      services: %{
        crf_searcher: service_state(),
        encoder: service_state()
      },
      auto_resume_hour: Keyword.get(config, :auto_resume_hour, @default_auto_resume_hour),
      auto_resume_after_ms:
        Keyword.get(config, :auto_resume_after_ms, @default_auto_resume_after_ms),
      auto_resume_timezone:
        Keyword.get(config, :auto_resume_timezone, @default_auto_resume_timezone),
      check_interval_ms: Keyword.get(config, :check_interval_ms, @check_interval_ms)
    }
  end

  defp service_state, do: %{suspended?: false, suspended_at: nil}

  defp put_service_state(state, service, suspended?, suspended_at) do
    put_in(state, [:services, service], %{suspended?: suspended?, suspended_at: suspended_at})
  end

  defp schedule_auto_resume_check(interval) do
    Process.send_after(self(), :auto_resume_check, interval)
  end

  defp maybe_auto_resume(state) do
    if auto_resume_window?(state) do
      Enum.reduce(@services, state, &maybe_auto_resume_service/2)
    else
      state
    end
  end

  defp auto_resume_window?(state) do
    case DateTime.now(state.auto_resume_timezone) do
      {:ok, now} -> now.hour == state.auto_resume_hour
      {:error, _} -> DateTime.utc_now().hour == state.auto_resume_hour
    end
  end

  defp maybe_auto_resume_service(service, state) do
    service_state = get_in(state, [:services, service])

    if old_enough_to_resume?(service_state, state.auto_resume_after_ms) do
      Logger.info("Auto-resuming #{service} after extended pause")
      resume_service(service)
      put_service_state(state, service, false, nil)
    else
      state
    end
  end

  defp old_enough_to_resume?(%{suspended?: true, suspended_at: %DateTime{} = suspended_at}, ms) do
    DateTime.diff(DateTime.utc_now(), suspended_at, :millisecond) >= ms
  end

  defp old_enough_to_resume?(_service_state, _ms), do: false

  defp resume_service(:crf_searcher), do: CrfSearch.resume_current()
  defp resume_service(:encoder), do: Encode.resume_current()

  if Mix.env() == :test do
    @doc false
    def force_suspend_at(service, suspended_at) when service in @services do
      GenServer.cast(__MODULE__, {:force_suspend_at, service, suspended_at})
    end

    @doc false
    def auto_resume_check do
      send(__MODULE__, :auto_resume_check)
    end
  end

  defp call_or_default(message, default) do
    case GenServer.whereis(__MODULE__) do
      nil -> default
      pid -> GenServer.call(pid, message)
    end
  catch
    :exit, _ -> default
  end

  defp cast_or_default(message) do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, message)
    end
  end
end
