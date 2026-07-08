defmodule Reencodarr.AbAv1.WorkerSessions do
  @moduledoc """
  Tracks connected ab-av1 worker websocket sessions.
  """

  use GenServer

  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Media
  alias Reencodarr.Media.VideoStateMachine

  @by_server_table :reencodarr_worker_sessions_by_server
  @by_client_table :reencodarr_worker_sessions_by_client

  @type session :: %{
          server_worker_id: String.t(),
          client_worker_id: String.t(),
          version: String.t(),
          protocol_version: pos_integer(),
          capabilities: map(),
          active_video_id: integer() | nil,
          transfer_progress: map() | nil,
          crf_search_progress: map() | nil,
          resource_usage: map() | nil,
          connected_at: DateTime.t(),
          last_seen_at: DateTime.t()
        }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def register(attrs) do
    GenServer.call(__MODULE__, {:register, attrs})
  end

  def touch(server_worker_id, resource_usage \\ nil) do
    GenServer.call(__MODULE__, {:touch, server_worker_id, resource_usage})
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

  def set_transfer_progress(server_worker_id, progress) when is_map(progress) do
    GenServer.call(__MODULE__, {:set_transfer_progress, server_worker_id, progress})
  end

  def set_crf_search_progress(server_worker_id, progress) when is_map(progress) do
    GenServer.call(__MODULE__, {:set_crf_search_progress, server_worker_id, progress})
  end

  def cancel(server_worker_id) do
    GenServer.call(__MODULE__, {:cancel, server_worker_id})
  end

  def drain do
    GenServer.call(__MODULE__, :drain)
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

    with {:ok, server_worker_id} <- required_attr(attrs, :server_worker_id),
         {:ok, client_worker_id} <- required_attr(attrs, :client_worker_id),
         {:ok, version} <- required_attr(attrs, :version),
         {:ok, protocol_version} <- required_attr(attrs, :protocol_version),
         {:ok, capabilities} <- required_attr(attrs, :capabilities) do
      register_session(
        server_worker_id,
        client_worker_id,
        version,
        protocol_version,
        capabilities,
        now,
        state
      )
    else
      :error ->
        {:reply, {:error, :invalid_session_attrs}, state}
    end
  end

  def handle_call({:touch, server_worker_id, resource_usage}, _from, state) do
    update_session_reply(server_worker_id, state, fn session ->
      %{session | last_seen_at: now(), resource_usage: resource_usage || session.resource_usage}
    end)
  end

  def handle_call({:unregister, server_worker_id}, _from, state) do
    :ok = drop_session(server_worker_id)
    broadcast_sessions()
    {:reply, :ok, state}
  end

  def handle_call({:assign_video, server_worker_id, video_id}, _from, state) do
    update_session_reply(server_worker_id, state, fn session ->
      %{session | active_video_id: video_id, transfer_progress: nil, crf_search_progress: nil}
    end)
  end

  def handle_call({:clear_video, server_worker_id}, _from, state) do
    update_session_reply(server_worker_id, state, fn session ->
      %{session | active_video_id: nil, transfer_progress: nil, crf_search_progress: nil}
    end)
  end

  def handle_call({:set_transfer_progress, server_worker_id, progress}, _from, state) do
    update_session_reply(server_worker_id, state, fn session ->
      active_video_id = Map.get(progress, :video_id, session.active_video_id)

      %{session | active_video_id: active_video_id, transfer_progress: progress}
    end)
  end

  def handle_call({:set_crf_search_progress, server_worker_id, progress}, _from, state) do
    update_session_reply(server_worker_id, state, fn session ->
      progress = merge_crf_search_progress(session.crf_search_progress, progress)

      %{session | transfer_progress: nil, crf_search_progress: progress}
    end)
  end

  def handle_call({:cancel, server_worker_id}, _from, state) do
    case lookup_session(server_worker_id) do
      {:ok, session} ->
        requeue_active_video(session)
        :ok = drop_session(server_worker_id)
        broadcast_sessions()
        {:reply, {:ok, session}, state}

      :error ->
        {:reply, {:error, :unknown_worker_session}, state}
    end
  end

  def handle_call({:get, server_worker_id}, _from, state) do
    {:reply, session_or_nil(lookup_session(server_worker_id)), state}
  end

  def handle_call({:expire_stale, timeout_seconds}, _from, state) do
    {expired_sessions, _} = expire_stale_sessions(timeout_seconds)

    if expired_sessions != [] do
      broadcast_sessions()
    end

    {:reply, {:ok, expired_sessions}, state}
  end

  def handle_call(:list, _from, state) do
    sessions = list_sessions()
    {:reply, sessions, state}
  end

  def handle_call(:reset, _from, state) do
    :ok = reset_tables()
    broadcast_sessions()
    {:reply, :ok, state}
  end

  def handle_call(:drain, _from, state) do
    drained_sessions =
      list_sessions()
      |> Enum.filter(&(&1.active_video_id != nil))
      |> Enum.map(fn session ->
        requeue_active_video(session)
        :ok = drop_session(session.server_worker_id)
        session
      end)

    if drained_sessions != [] do
      broadcast_sessions()
    end

    {:reply, {:ok, drained_sessions}, state}
  end

  @impl GenServer
  def handle_info(:expire_stale, state) do
    {expired_sessions, _} = expire_stale_sessions(timeout_seconds())

    if expired_sessions != [] do
      broadcast_sessions()
    end

    schedule_expire_stale()
    {:noreply, state}
  end

  defp build_session(
         server_worker_id,
         client_worker_id,
         version,
         protocol_version,
         capabilities,
         now
       ) do
    %{
      server_worker_id: server_worker_id,
      client_worker_id: client_worker_id,
      version: version,
      protocol_version: protocol_version,
      capabilities: capabilities,
      active_video_id: nil,
      transfer_progress: nil,
      crf_search_progress: nil,
      resource_usage: nil,
      connected_at: now,
      last_seen_at: now
    }
  end

  defp merge_crf_search_progress(
         %{video_id: video_id} = previous,
         %{video_id: video_id} = progress
       ) do
    Enum.reduce([:crf, :sample_num, :total_samples], progress, fn key, merged ->
      case Map.get(merged, key) do
        nil -> Map.put(merged, key, Map.get(previous, key))
        _value -> merged
      end
    end)
  end

  defp merge_crf_search_progress(_previous, progress), do: progress

  defp register_session(
         server_worker_id,
         client_worker_id,
         version,
         protocol_version,
         capabilities,
         now,
         state
       ) do
    case lookup_session(server_worker_id) do
      :error ->
        case lookup_client(client_worker_id) do
          nil ->
            session =
              build_session(
                server_worker_id,
                client_worker_id,
                version,
                protocol_version,
                capabilities,
                now
              )

            :ok = put_session(session)
            {:reply, {:ok, session}, state}

          existing_server_worker_id ->
            replace_client_session(
              existing_server_worker_id,
              server_worker_id,
              client_worker_id,
              version,
              protocol_version,
              capabilities,
              now,
              state
            )
        end

      {:ok, %{client_worker_id: ^client_worker_id, connected_at: connected_at}} ->
        session =
          build_session(
            server_worker_id,
            client_worker_id,
            version,
            protocol_version,
            capabilities,
            now
          )
          |> Map.put(:connected_at, connected_at)

        :ok = put_session(session)
        {:reply, {:ok, session}, state}

      {:ok, _existing_session} ->
        {:reply, {:error, :duplicate_worker_id}, state}
    end
  end

  defp replace_client_session(
         existing_server_worker_id,
         server_worker_id,
         client_worker_id,
         version,
         protocol_version,
         capabilities,
         now,
         state
       ) do
    case lookup_session(existing_server_worker_id) do
      {:ok, existing_session} ->
        active_video_id = resumable_active_video_id(existing_session.active_video_id)

        session =
          build_session(
            server_worker_id,
            client_worker_id,
            version,
            protocol_version,
            capabilities,
            now
          )
          |> Map.put(:connected_at, existing_session.connected_at)
          |> Map.put(:active_video_id, active_video_id)
          |> Map.put(
            :transfer_progress,
            if(active_video_id, do: existing_session.transfer_progress)
          )
          |> Map.put(
            :crf_search_progress,
            if(active_video_id, do: existing_session.crf_search_progress)
          )
          |> Map.put(:resource_usage, existing_session.resource_usage)

        :ok = drop_session(existing_server_worker_id)
        :ok = put_session(session)
        {:reply, {:ok, session}, state}

      :error ->
        {:reply, {:error, :duplicate_worker_id}, state}
    end
  end

  defp required_attr(attrs, key), do: Map.fetch(attrs, key)

  defp update_session_reply(server_worker_id, state, update_fun) do
    case lookup_session(server_worker_id) do
      {:ok, session} ->
        updated_session = update_fun.(session)
        :ok = put_session(updated_session)
        {:reply, {:ok, updated_session}, state}

      :error ->
        {:reply, {:error, :unknown_worker_session}, state}
    end
  end

  defp broadcast_sessions do
    Events.broadcast_event(:worker_sessions_updated, %{sessions: list_sessions()})
  end

  defp requeue_active_video(%{active_video_id: nil}), do: :ok

  defp requeue_active_video(%{active_video_id: video_id}) do
    case Media.get_video(video_id) do
      %Media.Video{state: :crf_searching} = video ->
        _ = VideoStateMachine.mark_as_analyzed(video)
        :ok

      _ ->
        :ok
    end
  end

  defp resumable_active_video_id(nil), do: nil

  defp resumable_active_video_id(video_id) do
    case Media.get_video(video_id) do
      %Media.Video{state: :crf_searching} -> video_id
      _ -> nil
    end
  end

  defp put_session(session) do
    :ok = drop_session(session.server_worker_id)
    true = :ets.insert(@by_server_table, {session.server_worker_id, session})
    true = :ets.insert(@by_client_table, {session.client_worker_id, session.server_worker_id})
    broadcast_sessions()
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
      requeue_active_video(session)
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
