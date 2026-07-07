defmodule Reencodarr.AbAv1.WorkerSessions do
  @moduledoc """
  Tracks connected ab-av1 worker websocket sessions.
  """

  use GenServer

  @type session :: %{
          server_worker_id: String.t(),
          client_worker_id: String.t(),
          version: String.t(),
          protocol_version: pos_integer(),
          capabilities: map(),
          connected_at: DateTime.t(),
          last_seen_at: DateTime.t()
        }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def register(attrs) do
    GenServer.call(__MODULE__, {:register, attrs})
  end

  def touch(server_worker_id) do
    GenServer.call(__MODULE__, {:touch, server_worker_id})
  end

  def unregister(server_worker_id) do
    GenServer.call(__MODULE__, {:unregister, server_worker_id})
  end

  def expire_stale(timeout_seconds) when is_integer(timeout_seconds) and timeout_seconds >= 0 do
    GenServer.call(__MODULE__, {:expire_stale, timeout_seconds})
  end

  def list do
    GenServer.call(__MODULE__, :list)
  end

  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @impl GenServer
  def init(_opts) do
    schedule_expire_stale()
    {:ok, %{by_server: %{}, by_client: %{}}}
  end

  @impl GenServer
  def handle_call({:register, attrs}, _from, state) do
    now = now()
    server_worker_id = Map.fetch!(attrs, :server_worker_id)
    client_worker_id = Map.fetch!(attrs, :client_worker_id)

    case Map.get(state.by_client, client_worker_id) do
      nil ->
        session = build_session(attrs, now)
        {:reply, {:ok, session}, put_session(state, session)}

      ^server_worker_id ->
        session =
          attrs
          |> build_session(now)
          |> Map.put(:connected_at, state.by_server[server_worker_id].connected_at)

        {:reply, {:ok, session}, put_session(state, session)}

      _other_server_worker_id ->
        {:reply, {:error, :duplicate_worker_id}, state}
    end
  end

  def handle_call({:touch, server_worker_id}, _from, state) do
    case Map.fetch(state.by_server, server_worker_id) do
      {:ok, session} ->
        updated_session = %{session | last_seen_at: now()}
        {:reply, {:ok, updated_session}, put_session(state, updated_session)}

      :error ->
        {:reply, {:error, :unknown_worker_session}, state}
    end
  end

  def handle_call({:unregister, server_worker_id}, _from, state) do
    {:reply, :ok, drop_session(state, server_worker_id)}
  end

  def handle_call({:expire_stale, timeout_seconds}, _from, state) do
    {expired_sessions, next_state} = expire_stale_sessions(state, timeout_seconds)
    {:reply, {:ok, expired_sessions}, next_state}
  end

  def handle_call(:list, _from, state) do
    sessions =
      state.by_server
      |> Map.values()
      |> Enum.sort_by(& &1.client_worker_id)

    {:reply, sessions, state}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{by_server: %{}, by_client: %{}}}
  end

  @impl GenServer
  def handle_info(:expire_stale, state) do
    {_expired_sessions, next_state} = expire_stale_sessions(state, timeout_seconds())
    schedule_expire_stale()
    {:noreply, next_state}
  end

  defp build_session(attrs, now) do
    %{
      server_worker_id: Map.fetch!(attrs, :server_worker_id),
      client_worker_id: Map.fetch!(attrs, :client_worker_id),
      version: Map.fetch!(attrs, :version),
      protocol_version: Map.fetch!(attrs, :protocol_version),
      capabilities: Map.fetch!(attrs, :capabilities),
      connected_at: now,
      last_seen_at: now
    }
  end

  defp put_session(state, session) do
    state
    |> drop_session(session.server_worker_id)
    |> then(fn state ->
      %{
        by_server: Map.put(state.by_server, session.server_worker_id, session),
        by_client: Map.put(state.by_client, session.client_worker_id, session.server_worker_id)
      }
    end)
  end

  defp drop_session(state, server_worker_id) do
    case Map.pop(state.by_server, server_worker_id) do
      {nil, by_server} ->
        %{state | by_server: by_server}

      {session, by_server} ->
        %{
          by_server: by_server,
          by_client: Map.delete(state.by_client, session.client_worker_id)
        }
    end
  end

  defp expire_stale_sessions(state, timeout_seconds) do
    now = now()

    Enum.reduce(state.by_server, {[], state}, fn {server_worker_id, session},
                                                 {expired, acc_state} ->
      age_seconds = DateTime.diff(now, session.last_seen_at, :second)

      if age_seconds >= timeout_seconds do
        {[session | expired], drop_session(acc_state, server_worker_id)}
      else
        {expired, acc_state}
      end
    end)
    |> then(fn {expired_sessions, next_state} ->
      {Enum.reverse(expired_sessions), next_state}
    end)
  end

  defp schedule_expire_stale do
    Process.send_after(self(), :expire_stale, sweep_interval_ms())
  end

  defp timeout_seconds do
    Application.get_env(:reencodarr, :worker_session_timeout_seconds, 120)
  end

  defp sweep_interval_ms do
    Application.get_env(:reencodarr, :worker_session_sweep_interval_ms, 30_000)
  end

  defp now do
    DateTime.utc_now() |> DateTime.truncate(:second)
  end
end
