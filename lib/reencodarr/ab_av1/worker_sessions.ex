defmodule Reencodarr.AbAv1.WorkerSessions do
  @moduledoc """
  Tracks connected ab-av1 worker websocket sessions.
  """

  use GenServer

  alias Reencodarr.AbAv1.WorkerJobStateMachine
  alias Reencodarr.AbAv1.WorkerProtocol.CrfSearchProgress
  alias Reencodarr.AbAv1.WorkerProtocol.EncodeProgress
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.DbWriter
  alias Reencodarr.Media
  alias Reencodarr.Media.VideoFailure

  require Logger

  @by_server_table :reencodarr_worker_sessions_by_server
  @by_client_table :reencodarr_worker_sessions_by_client
  @orphan_reset_grace_seconds 600
  @watchdog_warning_seconds 23 * 60 * 60
  @watchdog_recovery_seconds 24 * 60 * 60
  @worker_control_topic_prefix "worker_controls:"
  @worker_control_states %{pause: :paused, resume: :running, stop: :stopped}

  defmodule Job do
    @moduledoc false

    alias Reencodarr.AbAv1.WorkerProtocol.{CrfSearchProgress, EncodeProgress}

    @enforce_keys [:job_id, :job_type, :video_id]
    defstruct [
      :job_id,
      :job_type,
      :video_id,
      :transfer_progress,
      :progress,
      :last_activity_at,
      :recovery_action,
      active: true,
      phase: :assigned,
      control_state: :running,
      desired_control_state: :running,
      control_command_id: nil
    ]

    @type job_type :: :crf_search | :encode
    @type phase ::
            :assigned
            | :receiving_input
            | :input_ready
            | :crf_searching
            | :encoding
            | :output_upload
            | :terminal_delivery
            | :cleanup
    @type control_state :: :running | :paused | :stopped
    @type t :: %__MODULE__{
            job_id: String.t(),
            job_type: job_type(),
            video_id: pos_integer(),
            phase: phase(),
            control_state: control_state(),
            desired_control_state: control_state(),
            control_command_id: String.t() | nil,
            transfer_progress: map() | nil,
            progress: EncodeProgress.t() | CrfSearchProgress.t() | nil,
            last_activity_at: DateTime.t() | nil,
            recovery_action: nil | :warned | :stop_requested | :stale,
            active: boolean()
          }
  end

  @type job :: Job.t()

  @type session :: %{
          server_worker_id: String.t(),
          client_worker_id: String.t(),
          version: String.t(),
          protocol_version: pos_integer(),
          capabilities: map(),
          control_state: :running | :paused | :stopped,
          phase: :idle | :receiving_input | :input_ready | :crf_searching,
          active_video_id: integer() | nil,
          transfer_progress: map() | nil,
          crf_search_progress: CrfSearchProgress.t() | nil,
          resource_usage: map() | nil,
          resource_usage_at: DateTime.t() | nil,
          encode_admission: map() | nil,
          jobs: %{optional(String.t()) => job()},
          connected_at: DateTime.t(),
          last_seen_at: DateTime.t()
        }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec register(map()) :: {:ok, session()} | {:error, atom()}
  def register(attrs) do
    GenServer.call(__MODULE__, {:register, attrs})
  end

  @spec touch(String.t(), map() | nil) :: :ok
  def touch(server_worker_id, resource_usage \\ nil) do
    GenServer.cast(__MODULE__, {:touch, server_worker_id, resource_usage})
  end

  def unregister(server_worker_id) do
    GenServer.call(__MODULE__, {:unregister, server_worker_id})
  end

  def assign_video(server_worker_id, video_id, phase \\ :crf_searching, job_id \\ nil)
      when is_integer(video_id) and phase in [:receiving_input, :input_ready, :crf_searching] do
    GenServer.call(__MODULE__, {:assign_video, server_worker_id, video_id, phase, job_id})
  end

  def clear_video(server_worker_id) do
    GenServer.call(__MODULE__, {:clear_video, server_worker_id})
  end

  @spec assign_job(String.t(), Job.t()) :: {:ok, session()} | {:error, atom()}
  def assign_job(server_worker_id, %Job{} = job) when is_binary(server_worker_id) do
    GenServer.call(__MODULE__, {:assign_job, server_worker_id, job})
  end

  @spec set_job_transfer_progress(String.t(), String.t(), map(), Job.phase()) :: :ok
  def set_job_transfer_progress(server_worker_id, job_id, progress, phase)
      when is_binary(server_worker_id) and is_binary(job_id) and is_map(progress) and
             phase in [:receiving_input, :input_ready] do
    GenServer.cast(
      __MODULE__,
      {:set_job_transfer_progress, server_worker_id, job_id, progress, phase}
    )
  end

  @spec set_encode_progress(String.t(), EncodeProgress.t()) :: :ok
  def set_encode_progress(server_worker_id, %EncodeProgress{} = progress) do
    GenServer.cast(__MODULE__, {:set_encode_progress, server_worker_id, progress})
  end

  @spec clear_job(String.t(), String.t()) :: {:ok, session()} | {:error, atom()}
  def clear_job(server_worker_id, job_id) when is_binary(job_id) do
    GenServer.call(__MODULE__, {:clear_job, server_worker_id, job_id})
  end

  @spec set_job_control_state(String.t(), String.t(), Job.control_state()) ::
          {:ok, session()} | {:error, atom()}
  def set_job_control_state(server_worker_id, job_id, control_state)
      when is_binary(server_worker_id) and is_binary(job_id) and
             control_state in [:running, :paused, :stopped] do
    GenServer.call(__MODULE__, {:set_job_control_state, server_worker_id, job_id, control_state})
  end

  @spec request_job_control(String.t(), String.t(), Job.control_state(), String.t()) ::
          {:ok, session()} | {:error, atom()}
  def request_job_control(server_worker_id, job_id, desired_state, command_id)
      when is_binary(server_worker_id) and is_binary(job_id) and
             desired_state in [:running, :paused, :stopped] and is_binary(command_id) do
    GenServer.call(
      __MODULE__,
      {:request_job_control, server_worker_id, job_id, desired_state, command_id}
    )
  end

  @spec control_topic(String.t()) :: String.t()
  def control_topic(server_worker_id) when is_binary(server_worker_id),
    do: @worker_control_topic_prefix <> server_worker_id

  @spec request_control(String.t(), String.t() | nil, :pause | :resume | :start | :stop) ::
          :ok | :error
  def request_control(server_worker_id, nil, :start) when is_binary(server_worker_id) do
    broadcast_control(server_worker_id, {:worker_control, :start})
  end

  def request_control(server_worker_id, job_id, action)
      when is_binary(server_worker_id) and is_binary(job_id) and
             action in [:pause, :resume, :stop] do
    with %{jobs: %{^job_id => %{video_id: video_id}}} <- get(server_worker_id),
         {:ok, command} <- Media.request_worker_control(video_id, job_id, action),
         :ok <- notify_control(server_worker_id, command) do
      :ok
    else
      _ -> :error
    end
  end

  @spec resume_paused_before(DateTime.t()) :: non_neg_integer()
  def resume_paused_before(%DateTime{} = cutoff) do
    connected_jobs =
      for session <- list(), {job_id, _job} <- session.jobs, into: %{} do
        {job_id, session.server_worker_id}
      end

    cutoff
    |> Media.list_paused_worker_attempts_before()
    |> Enum.count(fn %{video_id: video_id, job_id: job_id} ->
      with {:ok, command} <- Media.request_worker_control(video_id, job_id, :resume),
           :ok <- notify_connected_control(connected_jobs[job_id], command) do
        true
      else
        _ -> false
      end
    end)
  end

  @spec set_transfer_progress(String.t(), map()) :: :ok
  def set_transfer_progress(server_worker_id, progress) when is_map(progress) do
    GenServer.cast(__MODULE__, {:set_transfer_progress, server_worker_id, progress})
  end

  def finish_transfer(server_worker_id) do
    GenServer.call(__MODULE__, {:finish_transfer, server_worker_id})
  end

  @spec set_crf_search_progress(String.t(), CrfSearchProgress.t()) :: :ok
  def set_crf_search_progress(server_worker_id, %CrfSearchProgress{} = progress) do
    GenServer.cast(__MODULE__, {:set_crf_search_progress, server_worker_id, progress})
  end

  def cancel(server_worker_id) do
    GenServer.call(__MODULE__, {:cancel, server_worker_id})
  end

  def set_control_state(server_worker_id, control_state, active_video_id \\ nil)
      when control_state in [:running, :paused, :stopped] and
             (is_nil(active_video_id) or is_integer(active_video_id)) do
    GenServer.call(
      __MODULE__,
      {:set_control_state, server_worker_id, control_state, active_video_id}
    )
  end

  def drain do
    GenServer.call(__MODULE__, :drain)
  end

  @spec get(String.t()) :: session() | nil
  def get(server_worker_id) do
    GenServer.call(__MODULE__, {:get, server_worker_id})
  end

  @spec disk_free_bytes(String.t(), non_neg_integer()) ::
          {:ok, non_neg_integer()}
          | {:error, :missing_disk_telemetry | :stale_disk_telemetry | :unknown_worker_session}
  def disk_free_bytes(server_worker_id, max_age_ms) do
    GenServer.call(__MODULE__, {:disk_free_bytes, server_worker_id, max_age_ms})
  end

  @spec set_encode_admission(String.t(), map()) :: :ok | {:error, :unknown_worker_session}
  def set_encode_admission(server_worker_id, admission) when is_map(admission) do
    GenServer.call(__MODULE__, {:set_encode_admission, server_worker_id, admission})
  end

  def expire_stale(timeout_seconds) when is_integer(timeout_seconds) and timeout_seconds >= 0 do
    GenServer.call(__MODULE__, {:expire_stale, timeout_seconds})
  end

  @spec list() :: [session()]
  def list do
    GenServer.call(__MODULE__, :list)
  end

  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @doc false
  @spec set_job_activity_at(String.t(), String.t(), DateTime.t()) :: :ok | {:error, atom()}
  def set_job_activity_at(server_worker_id, job_id, %DateTime{} = activity_at) do
    GenServer.call(__MODULE__, {:set_job_activity_at, server_worker_id, job_id, activity_at})
  end

  @spec check_stalled_jobs(DateTime.t()) :: :ok
  def check_stalled_jobs(%DateTime{} = checked_at) do
    GenServer.call(__MODULE__, {:check_stalled_jobs, checked_at})
  end

  @spec record_job_activity(String.t(), Job.phase() | nil) :: :ok
  def record_job_activity(job_id, phase) when is_binary(job_id) do
    GenServer.cast(__MODULE__, {:record_job_activity, job_id, phase})
  end

  defp notify_connected_control(nil, _command), do: :ok

  defp notify_connected_control(server_worker_id, command),
    do: notify_control(server_worker_id, command)

  defp notify_control(server_worker_id, command) do
    desired_state = Map.fetch!(@worker_control_states, command.action)

    with {:ok, _session} <-
           request_job_control(
             server_worker_id,
             command.job_id,
             desired_state,
             command.command_id
           ) do
      broadcast_control(
        server_worker_id,
        {:worker_control, command.action, command.job_id, command.command_id}
      )
    end
  end

  defp broadcast_control(server_worker_id, command) do
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, control_topic(server_worker_id), command)
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@by_server_table, [:named_table, :set, :private])
    :ets.new(@by_client_table, [:named_table, :set, :private])
    schedule_expire_stale()
    schedule_orphan_reset()
    schedule_watchdog()
    {:ok, %{started_at: now()}}
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

  def handle_call({:unregister, server_worker_id}, _from, state) do
    :ok = drop_session(server_worker_id)
    broadcast_sessions()
    {:reply, :ok, state}
  end

  def handle_call({:assign_video, server_worker_id, video_id, phase, job_id}, _from, state) do
    update_session_reply(server_worker_id, state, fn session ->
      with {:ok, session} <- WorkerJobStateMachine.assign_video(session, video_id, phase) do
        {:ok, put_crf_job(session, video_id, phase, job_id: job_id, progress: nil)}
      end
    end)
  end

  def handle_call({:clear_video, server_worker_id}, _from, state) do
    update_session_reply(server_worker_id, state, fn session ->
      clear_crf_work(session)
    end)
  end

  def handle_call({:assign_job, server_worker_id, %Job{} = job}, _from, state) do
    update_session_reply(server_worker_id, state, fn session ->
      job = mark_job_activity(job)
      %{session | jobs: Map.put(session.jobs, job.job_id, job), last_seen_at: now()}
    end)
  end

  def handle_call({:set_job_activity_at, server_worker_id, job_id, activity_at}, _from, state) do
    result =
      update_session(server_worker_id, fn session ->
        case Map.fetch(session.jobs, job_id) do
          {:ok, %Job{} = job} ->
            updated = %Job{job | last_activity_at: activity_at, recovery_action: nil}
            %{session | jobs: Map.put(session.jobs, job_id, updated)}

          :error ->
            {:error, :unknown_worker_session}
        end
      end)

    {:reply,
     case(result) do
       {:ok, _} -> :ok
       error -> error
     end, state}
  end

  def handle_call({:check_stalled_jobs, checked_at}, _from, state) do
    check_stalled_jobs_now(checked_at)
    {:reply, :ok, state}
  end

  def handle_call({:clear_job, server_worker_id, job_id}, _from, state) do
    update_session_reply(server_worker_id, state, fn session ->
      %{session | jobs: Map.delete(session.jobs, job_id), last_seen_at: now()}
    end)
  end

  def handle_call({:set_job_control_state, server_worker_id, job_id, control_state}, _from, state) do
    update_session_reply(server_worker_id, state, fn session ->
      case Map.fetch(session.jobs, job_id) do
        {:ok, %Job{} = job} when control_state == :stopped ->
          stop_job(session, job_id, job)

        {:ok, %Job{} = job} ->
          job = activity_after_control(job, control_state)

          %{
            session
            | jobs:
                Map.put(
                  session.jobs,
                  job_id,
                  %Job{
                    job
                    | control_state: control_state,
                      desired_control_state: control_state,
                      control_command_id: nil
                  }
                ),
              last_seen_at: now()
          }

        :error ->
          {:error, :unknown_worker_session}
      end
    end)
  end

  def handle_call(
        {:request_job_control, server_worker_id, job_id, desired_state, command_id},
        _from,
        state
      ) do
    update_session_reply(server_worker_id, state, fn session ->
      case Map.fetch(session.jobs, job_id) do
        {:ok, %Job{} = job} ->
          requested_job = %Job{
            job
            | desired_control_state: desired_state,
              control_command_id: command_id
          }

          %{session | jobs: Map.put(session.jobs, job_id, requested_job)}

        :error ->
          {:error, :unknown_worker_session}
      end
    end)
  end

  def handle_call({:finish_transfer, server_worker_id}, _from, state) do
    update_session_reply(server_worker_id, state, fn session ->
      with {:ok, session} <- WorkerJobStateMachine.finish_transfer(session) do
        {:ok,
         session
         |> maybe_put_crf_job(session.active_video_id, :input_ready)
         |> Map.put(:last_seen_at, now())}
      end
    end)
  end

  def handle_call(
        {:set_control_state, server_worker_id, control_state, active_video_id},
        _from,
        state
      ) do
    update_session_reply(server_worker_id, state, fn session ->
      with {:ok, session} <- restore_active_video(session, active_video_id) do
        apply_control_state(session, control_state)
      end
    end)
  end

  def handle_call({:cancel, server_worker_id}, _from, state) do
    case lookup_session(server_worker_id) do
      {:ok, session} ->
        requeue_jobs(session.jobs)
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

  def handle_call({:disk_free_bytes, server_worker_id, max_age_ms}, _from, state) do
    result =
      case lookup_session(server_worker_id) do
        {:ok,
         %{
           resource_usage: %{disk_free_bytes: bytes},
           resource_usage_at: %DateTime{} = measured_at
         }}
        when is_integer(bytes) ->
          if DateTime.diff(DateTime.utc_now(), measured_at, :millisecond) <= max_age_ms,
            do: {:ok, bytes},
            else: {:error, :stale_disk_telemetry}

        {:ok, _session} ->
          {:error, :missing_disk_telemetry}

        :error ->
          {:error, :unknown_worker_session}
      end

    {:reply, result, state}
  end

  def handle_call({:set_encode_admission, server_worker_id, admission}, _from, state) do
    case lookup_session(server_worker_id) do
      {:ok, session} ->
        admission = Map.put(admission, :checked_at, now())
        maybe_log_encode_admission(session, admission)
        :ok = put_session(%{session | encode_admission: admission})
        broadcast_sessions()
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :unknown_worker_session}, state}
    end
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
    {:reply, :ok, %{state | started_at: now()}}
  end

  def handle_call(:drain, _from, state) do
    drained_sessions =
      list_sessions()
      |> Enum.filter(&(&1.active_video_id != nil or map_size(&1.jobs) > 0))
      |> Enum.map(fn session ->
        requeue_jobs(session.jobs)
        :ok = drop_session(session.server_worker_id)
        session
      end)

    if drained_sessions != [] do
      broadcast_sessions()
    end

    {:reply, {:ok, drained_sessions}, state}
  end

  @impl GenServer
  def handle_cast({:touch, server_worker_id, resource_usage}, state) do
    update_telemetry(server_worker_id, state, &touch_session(&1, resource_usage))
  end

  def handle_cast(
        {:set_job_transfer_progress, server_worker_id, job_id, progress, phase},
        state
      ) do
    update_telemetry(
      server_worker_id,
      state,
      &put_job_transfer_progress(&1, job_id, progress, phase),
      {:transfer_progress, Map.put(progress, :worker_id, server_worker_id)}
    )
  end

  def handle_cast({:record_job_activity, job_id, phase}, state) do
    Enum.each(list_sessions(), fn session ->
      case Map.fetch(session.jobs, job_id) do
        {:ok, %Job{} = job} ->
          updated_phase = phase || job.phase
          updated = mark_job_activity(%Job{job | phase: updated_phase})

          updated_session = %{
            session
            | jobs: Map.put(session.jobs, job_id, updated),
              last_seen_at: now()
          }

          store_activity_update(updated_session, job.phase, updated_phase)

        :error ->
          :ok
      end
    end)

    {:noreply, state}
  end

  def handle_cast({:set_encode_progress, server_worker_id, %EncodeProgress{} = progress}, state) do
    update_telemetry(
      server_worker_id,
      state,
      &put_encode_progress(&1, progress),
      {:encoding_progress, Map.from_struct(progress)}
    )
  end

  def handle_cast({:set_transfer_progress, server_worker_id, progress}, state) do
    update_telemetry(
      server_worker_id,
      state,
      &put_transfer_progress(&1, progress),
      {:transfer_progress, Map.put(progress, :worker_id, server_worker_id)}
    )
  end

  def handle_cast(
        {:set_crf_search_progress, server_worker_id, %CrfSearchProgress{} = progress},
        state
      ) do
    update_telemetry(
      server_worker_id,
      state,
      &put_crf_search_progress(&1, progress),
      {:crf_search_progress, progress}
    )
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

  def handle_info(:reset_orphans, state) do
    crf_attempt_ids = live_attempt_ids(:crf_search)
    encode_attempt_ids = live_attempt_ids(:encode)

    DbWriter.enqueue(
      fn ->
        :ok = Media.release_worker_terminal_claims_before(state.started_at)
        :ok = Media.reset_orphaned_crf_searching(crf_attempt_ids)
        :ok = Media.reset_orphaned_encoding(encode_attempt_ids)
      end,
      label: :worker_orphan_recovery
    )

    schedule_orphan_reset()
    {:noreply, state}
  end

  def handle_info(:check_stalled_jobs, state) do
    check_stalled_jobs_now(now())
    schedule_watchdog()
    {:noreply, state}
  end

  defp touch_session(session, nil), do: %{session | last_seen_at: now()}

  defp touch_session(session, resource_usage) do
    measured_at = DateTime.utc_now()

    %{
      session
      | last_seen_at: now(),
        resource_usage: resource_usage,
        resource_usage_at: measured_at
    }
  end

  defp put_job_transfer_progress(session, job_id, progress, phase) do
    case Map.fetch(session.jobs, job_id) do
      {:ok, %Job{} = job} ->
        updated_job = mark_job_activity(%Job{job | phase: phase, transfer_progress: progress})

        %{
          session
          | jobs: Map.put(session.jobs, job_id, updated_job),
            last_seen_at: now()
        }

      :error ->
        {:error, :unknown_worker_session}
    end
  end

  defp put_encode_progress(session, %EncodeProgress{} = progress) do
    job =
      case Map.fetch(session.jobs, progress.job_id) do
        {:ok, %Job{job_type: :encode} = job} ->
          mark_job_activity(%Job{job | phase: :encoding, progress: progress})

        _ ->
          mark_job_activity(%Job{
            job_id: progress.job_id,
            job_type: :encode,
            video_id: progress.video_id,
            phase: :encoding,
            progress: progress
          })
      end

    %{session | jobs: Map.put(session.jobs, progress.job_id, job), last_seen_at: now()}
  end

  defp put_transfer_progress(session, progress) do
    with {:ok, session} <- WorkerJobStateMachine.record_transfer_progress(session, progress) do
      job_id = Map.get(progress, :job_id) || Integer.to_string(session.active_video_id)

      {:ok,
       session
       |> put_crf_job(session.active_video_id, session.phase,
         job_id: job_id,
         transfer_progress: progress,
         progress: nil
       )
       |> Map.put(:last_seen_at, now())}
    end
  end

  defp put_crf_search_progress(session, %CrfSearchProgress{} = progress) do
    job_id = progress.job_id || Integer.to_string(progress.video_id)
    existing_job = Enum.find(Map.values(session.jobs), &match?(%Job{job_type: :crf_search}, &1))

    with :ok <- ensure_crf_video(existing_job, progress.video_id) do
      progress = merge_crf_search_progress(crf_progress(existing_job), progress)

      {:ok,
       session
       |> put_crf_job(progress.video_id, :crf_searching,
         job_id: job_id,
         progress: progress,
         transfer_progress: nil
       )
       |> Map.put(:last_seen_at, now())}
    end
  end

  defp ensure_crf_video(%Job{video_id: video_id}, expected_video_id)
       when video_id != expected_video_id,
       do: {:error, :invalid_worker_phase}

  defp ensure_crf_video(_job, _expected_video_id), do: :ok

  defp crf_progress(%Job{progress: %CrfSearchProgress{} = progress}), do: progress
  defp crf_progress(_job), do: nil

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
      control_state: :running,
      phase: :idle,
      active_video_id: nil,
      transfer_progress: nil,
      crf_search_progress: nil,
      resource_usage: nil,
      resource_usage_at: nil,
      encode_admission: nil,
      jobs: %{},
      connected_at: now,
      last_seen_at: now
    }
  end

  defp merge_crf_search_progress(
         %CrfSearchProgress{video_id: video_id} = previous,
         %CrfSearchProgress{video_id: video_id} = progress
       ) do
    %CrfSearchProgress{
      progress
      | crf: progress.crf || previous.crf,
        sample_num: progress.sample_num || previous.sample_num,
        total_samples: progress.total_samples || previous.total_samples
    }
  end

  defp merge_crf_search_progress(_previous, %CrfSearchProgress{} = progress), do: progress

  @spec put_crf_job(session(), pos_integer(), Job.phase(), keyword()) :: session()
  defp put_crf_job(session, video_id, phase, opts \\ []) when is_integer(video_id) do
    job_id = Keyword.get(opts, :job_id) || Integer.to_string(video_id)

    job =
      case Enum.find(
             Map.values(session.jobs),
             &match?(%Job{job_type: :crf_search, video_id: ^video_id}, &1)
           ) do
        %Job{} = job ->
          job

        nil ->
          %Job{
            job_id: job_id,
            job_type: :crf_search,
            video_id: video_id,
            control_state: session.control_state
          }
      end

    job = %Job{
      job
      | job_id: job_id,
        phase: phase,
        transfer_progress: Keyword.get(opts, :transfer_progress, job.transfer_progress),
        progress: Keyword.get(opts, :progress, job.progress)
    }

    job = mark_job_activity(job)

    jobs =
      session.jobs
      |> Map.reject(fn {_job_id, job} -> job.job_type == :crf_search end)
      |> Map.put(job_id, job)

    %{session | jobs: jobs}
  end

  @spec maybe_put_crf_job(session(), pos_integer() | nil, Job.phase()) :: session()
  defp maybe_put_crf_job(session, nil, _phase), do: session
  defp maybe_put_crf_job(session, video_id, phase), do: put_crf_job(session, video_id, phase)

  @spec clear_crf_work(session()) :: {:ok, session()}
  defp clear_crf_work(session) do
    with {:ok, session} <- WorkerJobStateMachine.clear_video(session) do
      {:ok,
       %{
         session
         | jobs: Map.reject(session.jobs, fn {_job_id, job} -> job.job_type == :crf_search end)
       }}
    end
  end

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
        jobs = resumable_jobs(existing_session.jobs, client_worker_id)
        crf_job = Enum.find(Map.values(jobs), &match?(%Job{job_type: :crf_search}, &1))
        active_video_id = crf_job && crf_job.video_id

        phase =
          if crf_job, do: resumable_phase(crf_job.phase), else: :idle

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
          |> Map.put(:phase, phase)
          |> Map.put(
            :transfer_progress,
            if(active_video_id && phase in [:receiving_input, :input_ready],
              do: existing_session.transfer_progress
            )
          )
          |> Map.put(
            :crf_search_progress,
            if(active_video_id && phase == :crf_searching,
              do: existing_session.crf_search_progress
            )
          )
          |> Map.put(:resource_usage, existing_session.resource_usage)
          |> Map.put(:jobs, jobs)

        :ok = drop_session(existing_server_worker_id)
        :ok = put_session(session)
        {:reply, {:ok, session}, state}

      :error ->
        {:reply, {:error, :duplicate_worker_id}, state}
    end
  end

  defp required_attr(attrs, key), do: Map.fetch(attrs, key)

  defp resumable_phase(phase) when phase in [:receiving_input, :input_ready, :crf_searching],
    do: phase

  defp resumable_phase(_phase), do: :crf_searching

  defp update_session_reply(server_worker_id, state, update_fun) do
    {:reply, update_session(server_worker_id, update_fun), state}
  end

  defp update_session(server_worker_id, update_fun) do
    case lookup_session(server_worker_id) do
      {:ok, session} ->
        case update_fun.(session) do
          {:ok, updated_session} ->
            updated_session = derive_crf_summary(updated_session)
            :ok = put_session(updated_session)
            {:ok, updated_session}

          {:error, reason} ->
            {:error, reason}

          updated_session ->
            updated_session = derive_crf_summary(updated_session)
            :ok = put_session(updated_session)
            {:ok, updated_session}
        end

      :error ->
        {:error, :unknown_worker_session}
    end
  end

  defp update_telemetry(server_worker_id, state, update_fun, event \\ nil) do
    case {update_session(server_worker_id, update_fun), event} do
      {{:ok, _session}, {event_name, payload}} ->
        Events.broadcast_event(event_name, payload)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  defp broadcast_sessions do
    Events.broadcast_event(:worker_sessions_updated, %{sessions: list_sessions()})
  end

  defp restore_active_video(session, nil), do: {:ok, session}

  defp restore_active_video(%{active_video_id: nil} = session, video_id) do
    with {:ok, session} <-
           WorkerJobStateMachine.assign_video(session, video_id, :crf_searching) do
      {:ok, put_crf_job(session, video_id, :crf_searching)}
    end
  end

  defp restore_active_video(%{active_video_id: video_id} = session, video_id),
    do: {:ok, session}

  defp restore_active_video(_session, _video_id), do: {:error, :invalid_worker_phase}

  defp apply_control_state(session, :stopped) do
    fail_active_video(session)
    fail_encode_jobs(session.jobs)
    {:ok, session} = clear_crf_work(session)
    %{session | control_state: :stopped, jobs: %{}, last_seen_at: now()}
  end

  defp apply_control_state(session, control_state) do
    jobs =
      Map.new(session.jobs, fn
        {job_id, %Job{job_type: :crf_search} = job} ->
          {job_id,
           %Job{
             job
             | control_state: control_state,
               desired_control_state: control_state,
               control_command_id: nil
           }}

        entry ->
          entry
      end)

    %{session | jobs: jobs, control_state: control_state, last_seen_at: now()}
  end

  defp fail_active_video(%{active_video_id: nil}), do: :ok

  defp fail_active_video(%{active_video_id: video_id}) do
    case Media.get_video(video_id) do
      %Media.Video{} = video -> _ = Media.fail_video_by_operator(video, :crf_search)
      nil -> :ok
    end
  end

  defp requeue_jobs(jobs) do
    Enum.each(jobs, fn
      {job_id, %Job{job_type: job_type, video_id: video_id}}
      when job_type in [:crf_search, :encode] ->
        Media.requeue_worker_attempt(video_id, job_id, job_type)

      _ ->
        :ok
    end)
  end

  defp fail_encode_jobs(jobs) do
    jobs
    |> Map.values()
    |> Enum.filter(&match?(%Job{job_type: :encode}, &1))
    |> Enum.each(&fail_job/1)
  end

  @spec stop_job(session(), String.t(), Job.t()) :: session() | {:error, term()}
  defp stop_job(session, _job_id, %Job{job_type: :crf_search}) do
    with {:ok, session} <- clear_crf_work(session) do
      %{session | last_seen_at: now()}
    end
  end

  defp stop_job(session, job_id, %Job{}),
    do: %{session | jobs: Map.delete(session.jobs, job_id), last_seen_at: now()}

  @spec fail_job(Job.t()) :: {:ok, VideoFailure.t() | nil} | {:error, term()}
  defp fail_job(%Job{} = job) do
    case {job.job_type, Media.get_video(job.video_id)} do
      {:encode, %Media.Video{} = video} ->
        _ = Media.fail_video_by_operator(video, :encoding)

      {:crf_search, %Media.Video{} = video} ->
        _ = Media.fail_video_by_operator(video, :crf_search)

      _ ->
        :ok
    end
  end

  defp resumable_jobs(jobs, client_worker_id) do
    jobs
    |> Map.filter(fn {job_id, job} ->
      case {job.job_type, Media.get_video(job.video_id)} do
        {:crf_search,
         %Media.Video{
           state: :crf_searching,
           crf_search_worker_id: ^client_worker_id,
           worker_attempt_id: ^job_id
         }} ->
          true

        {:encode,
         %Media.Video{
           state: :encoding,
           encode_worker_id: ^client_worker_id,
           worker_attempt_id: ^job_id
         }} ->
          true

        _ ->
          false
      end
    end)
    |> Map.new(fn
      {job_id, %Job{job_type: :encode} = job} -> {job_id, %Job{job | active: false}}
      entry -> entry
    end)
  end

  defp put_session(session) do
    session = derive_crf_summary(session)
    :ok = store_session(session)
    broadcast_sessions()
    :ok
  end

  defp store_session(session) do
    session = derive_crf_summary(session)
    :ok = drop_session(session.server_worker_id)
    true = :ets.insert(@by_server_table, {session.server_worker_id, session})
    true = :ets.insert(@by_client_table, {session.client_worker_id, session.server_worker_id})
    :ok
  end

  defp derive_crf_summary(session) do
    case Enum.find(Map.values(session.jobs), &match?(%Job{job_type: :crf_search}, &1)) do
      %Job{} = job ->
        %{
          session
          | active_video_id: job.video_id,
            phase: job.phase,
            transfer_progress: job.transfer_progress,
            crf_search_progress: job.progress
        }

      nil ->
        session
    end
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

  defp live_attempt_ids(job_type) do
    @by_server_table
    |> :ets.tab2list()
    |> Enum.flat_map(fn {_server_worker_id, session} ->
      Enum.flat_map(session.jobs, fn
        {job_id, %Job{job_type: ^job_type}} -> [job_id]
        _ -> []
      end)
    end)
  end

  defp schedule_expire_stale do
    Process.send_after(self(), :expire_stale, sweep_interval_ms())
  end

  defp schedule_orphan_reset do
    Process.send_after(self(), :reset_orphans, @orphan_reset_grace_seconds * 1_000)
  end

  defp schedule_watchdog do
    Process.send_after(self(), :check_stalled_jobs, watchdog_interval_ms())
  end

  defp check_stalled_jobs_now(checked_at) do
    changed? =
      Enum.reduce(list_sessions(), false, fn session, changed? ->
        jobs =
          Map.new(session.jobs, fn {job_id, job} ->
            {job_id, check_job(session, job, checked_at)}
          end)

        if jobs == session.jobs do
          changed?
        else
          :ok = store_session(%{session | jobs: jobs})
          true
        end
      end)

    if changed?, do: broadcast_sessions()
  end

  defp check_job(_session, %Job{control_state: :paused} = job, _checked_at), do: job
  defp check_job(_session, %Job{desired_control_state: :paused} = job, _checked_at), do: job

  defp check_job(_session, %Job{recovery_action: action} = job, _checked_at)
       when action in [:stop_requested, :stale], do: job

  defp check_job(session, %Job{last_activity_at: %DateTime{} = activity_at} = job, checked_at) do
    age = DateTime.diff(checked_at, activity_at, :second)
    thresholds = watchdog_thresholds(job.phase)

    cond do
      age >= thresholds.recovery -> request_stalled_stop(session, job, age)
      age >= thresholds.warning -> warn_stalled_job(session, job, age)
      true -> job
    end
  end

  defp check_job(_session, job, _checked_at), do: mark_job_activity(job)

  defp warn_stalled_job(_session, %Job{recovery_action: :warned} = job, _age), do: job

  defp warn_stalled_job(session, %Job{} = job, age) do
    Logger.warning(
      "Worker job may be stalled: worker=#{session.client_worker_id} job_id=#{job.job_id} phase=#{job.phase} stall_seconds=#{age}"
    )

    %Job{job | recovery_action: :warned}
  end

  defp request_stalled_stop(session, %Job{} = job, age) do
    case Media.request_worker_control(job.video_id, job.job_id, :stop, :stalled) do
      {:ok, command} ->
        Logger.error(
          "Stopping stalled worker job: worker=#{session.client_worker_id} job_id=#{job.job_id} phase=#{job.phase} stall_seconds=#{age}"
        )

        :ok =
          broadcast_control(
            session.server_worker_id,
            {:worker_control, :stop, job.job_id, command.command_id}
          )

        %Job{
          job
          | desired_control_state: :stopped,
            control_command_id: command.command_id,
            recovery_action: :stop_requested
        }

      {:error, :stale_worker_attempt} ->
        %Job{job | recovery_action: :stale}

      {:error, reason} ->
        Logger.error(
          "Unable to stop stalled worker job: worker=#{session.client_worker_id} job_id=#{job.job_id} reason=#{inspect(reason)}"
        )

        job

      result ->
        Logger.error(
          "Unexpected stalled worker stop result: worker=#{session.client_worker_id} job_id=#{job.job_id} result=#{inspect(result)}"
        )

        job
    end
  end

  defp mark_job_activity(%Job{} = job),
    do: %Job{job | last_activity_at: now(), recovery_action: nil}

  @spec activity_after_control(Job.t(), Job.control_state()) :: Job.t()
  defp activity_after_control(%Job{} = job, :running), do: mark_job_activity(job)
  defp activity_after_control(%Job{} = job, _control_state), do: job

  defp store_activity_update(session, phase, phase), do: store_session(session)
  defp store_activity_update(session, _old_phase, _new_phase), do: put_session(session)

  defp watchdog_thresholds(phase) do
    defaults = %{warning: @watchdog_warning_seconds, recovery: @watchdog_recovery_seconds}
    overrides = Application.get_env(:reencodarr, :worker_watchdog_thresholds, %{})
    Map.merge(defaults, Map.get(overrides, phase, %{}))
  end

  defp watchdog_interval_ms do
    Application.get_env(:reencodarr, :worker_watchdog_interval_ms, 60_000)
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

  defp maybe_log_encode_admission(
         %{encode_admission: %{status: :blocked, reason: reason}},
         %{status: :blocked, reason: reason}
       ),
       do: :ok

  defp maybe_log_encode_admission(session, %{status: :blocked} = admission) do
    Logger.warning(
      "Worker encode admission blocked: worker=#{session.client_worker_id} reason=#{admission.reason} available_bytes=#{admission[:available_bytes] || "unknown"} required_bytes=#{admission[:required_bytes] || "unknown"}"
    )
  end

  defp maybe_log_encode_admission(_session, _admission), do: :ok
end
