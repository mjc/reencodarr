defmodule Reencodarr.AbAv1.WorkerSessions do
  @moduledoc """
  Tracks connected ab-av1 worker websocket sessions.
  """

  use GenServer

  @by_server_table :reencodarr_worker_sessions_by_server
  @by_client_table :reencodarr_worker_sessions_by_client

  @type session :: %{
          server_worker_id: String.t(),
          client_worker_id: String.t(),
          version: String.t(),
          protocol_version: pos_integer(),
          capabilities: map(),
          active_video_id: integer() | nil,
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

  def assign_video(server_worker_id, video_id) when is_integer(video_id) do
    GenServer.call(__MODULE__, {:assign_video, server_worker_id, video_id})
  end

  def clear_video(server_worker_id) do
    GenServer.call(__MODULE__, {:clear_video, server_worker_id})
  end

  def get(server_worker_id) do
    GenServer.call(__MODULE__, {:get, server_worker_id})
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
    :ets.new(@by_server_table, [:named_table, :set, :private])
    :ets.new(@by_client_table, [:named_table, :set, :private])
    schedule_expire_stale()
    {:ok, :ok}
  end

  @impl GenServer
  def handle_call({:register, attrs}, _from, state) do
    now = now()
    server_worker_id = Map.fetch!(attrs, :server_worker_id)
    client_worker_id = Map.fetch!(attrs, :client_worker_id)

    case lookup_client(client_worker_id) do
      nil ->
        session = build_session(attrs, now)
        :ok = put_session(session)
        {:reply, {:ok, session}, state}

      ^server_worker_id ->
        connected_at = lookup_session!(server_worker_id).connected_at

        session =
          attrs
          |> build_session(now)
          |> Map.put(:connected_at, connected_at)

        :ok = put_session(session)
        {:reply, {:ok, session}, state}

      _other_server_worker_id ->
        {:reply, {:error, :duplicate_worker_id}, state}
    end
  end

  def handle_call({:touch, server_worker_id}, _from, state) do
    case lookup_session(server_worker_id) do
      {:ok, session} ->
        updated_session = %{session | last_seen_at: now()}
        :ok = put_session(updated_session)
        {:reply, {:ok, updated_session}, state}

      :error ->
        {:reply, {:error, :unknown_worker_session}, state}
    end
  end

  def handle_call({:unregister, server_worker_id}, _from, state) do
    :ok = drop_session(server_worker_id)
    {:reply, :ok, state}
  end

  def handle_call({:assign_video, server_worker_id, video_id}, _from, state) do
    case lookup_session(server_worker_id) do
      {:ok, session} ->
        updated_session = %{session | active_video_id: video_id}
        :ok = put_session(updated_session)
        {:reply, {:ok, updated_session}, state}

      :error ->
        {:reply, {:error, :unknown_worker_session}, state}
    end
  end

  def handle_call({:clear_video, server_worker_id}, _from, state) do
    case lookup_session(server_worker_id) do
      {:ok, session} ->
        updated_session = %{session | active_video_id: nil}
        :ok = put_session(updated_session)
        {:reply, {:ok, updated_session}, state}

      :error ->
        {:reply, {:error, :unknown_worker_session}, state}
    end
  end

  def handle_call({:get, server_worker_id}, _from, state) do
    {:reply, session_or_nil(lookup_session(server_worker_id)), state}
  end

  def handle_call({:expire_stale, timeout_seconds}, _from, state) do
    {expired_sessions, _} = expire_stale_sessions(timeout_seconds)
    {:reply, {:ok, expired_sessions}, state}
  end

  def handle_call(:list, _from, state) do
    sessions = list_sessions()
    {:reply, sessions, state}
  end

  def handle_call(:reset, _from, state) do
    :ok = reset_tables()
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:expire_stale, state) do
    _ = expire_stale_sessions(timeout_seconds())
    schedule_expire_stale()
    {:noreply, state}
  end

  defp build_session(attrs, now) do
    %{
      server_worker_id: Map.fetch!(attrs, :server_worker_id),
      client_worker_id: Map.fetch!(attrs, :client_worker_id),
      version: Map.fetch!(attrs, :version),
      protocol_version: Map.fetch!(attrs, :protocol_version),
      capabilities: Map.fetch!(attrs, :capabilities),
      active_video_id: nil,
      connected_at: now,
      last_seen_at: now
    }
  end

  defp put_session(session) do
    :ok = drop_session(session.server_worker_id)
    true = :ets.insert(@by_server_table, {session.server_worker_id, session})
    true = :ets.insert(@by_client_table, {session.client_worker_id, session.server_worker_id})
    :ok
  end

  defp drop_session(server_worker_id) do
    case lookup_session(server_worker_id) do
      {:ok, session} ->
        true = :ets.delete(@by_server_table, server_worker_id)
        true = :ets.delete(@by_client_table, session.client_worker_id)
        :ok

      :error ->
        :ok
    end
  end

  defp expire_stale_sessions(timeout_seconds) do
    now = now()

    expired_sessions =
      @by_server_table
      |> :ets.tab2list()
      |> Enum.map(fn {_server_worker_id, session} -> session end)
      |> Enum.filter(fn session ->
        DateTime.diff(now, session.last_seen_at, :second) >= timeout_seconds
      end)

    Enum.each(expired_sessions, fn session ->
      :ok = drop_session(session.server_worker_id)
    end)

    {expired_sessions, :ok}
  end

  defp schedule_expire_stale do
    Process.send_after(self(), :expire_stale, sweep_interval_ms())
  end

  defp reset_tables do
    true = :ets.delete_all_objects(@by_server_table)
    true = :ets.delete_all_objects(@by_client_table)
    :ok
  end

  defp list_sessions do
    @by_server_table
    |> :ets.tab2list()
    |> Enum.map(fn {_server_worker_id, session} -> session end)
    |> Enum.sort_by(& &1.client_worker_id)
  end

  defp lookup_session(server_worker_id) do
    case :ets.lookup(@by_server_table, server_worker_id) do
      [{^server_worker_id, session}] -> {:ok, session}
      [] -> :error
    end
  end

  defp lookup_session!(server_worker_id) do
    {:ok, session} = lookup_session(server_worker_id)
    session
  end

  defp lookup_client(client_worker_id) do
    case :ets.lookup(@by_client_table, client_worker_id) do
      [{^client_worker_id, server_worker_id}] -> server_worker_id
      [] -> nil
    end
  end

  defp session_or_nil({:ok, session}), do: session
  defp session_or_nil(:error), do: nil

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
