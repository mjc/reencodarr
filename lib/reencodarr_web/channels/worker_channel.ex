defmodule ReencodarrWeb.WorkerChannel do
  @moduledoc """
  Phoenix channel for long-lived ab-av1 CRF-search workers.
  """

  use ReencodarrWeb, :channel

  require Logger

  alias Reencodarr.AbAv1.{CrfSearch, WorkerConfig, WorkerProtocol, WorkerSessions}
  alias Reencodarr.AbAv1.WorkerProtocol.Announcement
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Media

  @crf_search_topic WorkerProtocol.crf_search_topic()
  @worker_control_topic_prefix "worker_controls:"

  def worker_control_topic(worker_id), do: @worker_control_topic_prefix <> worker_id

  @impl true
  def join(@crf_search_topic, _payload, %{assigns: %{worker_id: worker_id}} = socket) do
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, worker_control_topic(worker_id))
    {:ok, %{worker_id: worker_id}, socket}
  end

  def join(_topic, _payload, _socket), do: {:error, WorkerProtocol.error(:unauthorized)}

  @impl true
  def handle_in("announce", payload, %{assigns: %{worker_id: server_worker_id}} = socket) do
    with {:ok,
          %Announcement{
            worker_id: client_worker_id,
            hostname: hostname,
            protocol_version: protocol_version,
            version: version,
            capabilities: capabilities
          }} <- WorkerProtocol.parse_announcement(payload),
         :ok <- ensure_supported_protocol_version(protocol_version),
         {:ok, session} <-
           WorkerSessions.register(%{
             server_worker_id: server_worker_id,
             client_worker_id: client_worker_id,
             protocol_version: protocol_version,
             version: version,
             capabilities: capabilities
           }) do
      socket =
        socket
        |> assign(:local_worker, local_worker?(socket, hostname))
        |> assign(:client_worker_id, client_worker_id)
        |> assign(:client_version, version)
        |> assign(:protocol_version, protocol_version)
        |> assign(:capabilities, capabilities)
        |> attach_announced_work(client_worker_id, session)

      {:reply, {:ok, WorkerProtocol.accepted(protocol_version)}, socket}
    else
      {:error, reason} ->
        {:reply, {:error, WorkerProtocol.error(reason)}, socket}
    end
  end

  def handle_in("heartbeat", payload, %{assigns: %{worker_id: worker_id}} = socket) do
    case WorkerSessions.touch(worker_id, WorkerProtocol.parse_resource_usage(payload)) do
      {:ok, session} ->
        {:reply, {:ok, WorkerProtocol.heartbeat_ack(session.last_seen_at)}, socket}

      {:error, reason} ->
        {:reply, {:error, WorkerProtocol.error(reason)}, socket}
    end
  end

  def handle_in("control_state", payload, %{assigns: %{worker_id: worker_id}} = socket) do
    with {:ok, control_state, active_video_id} <- WorkerProtocol.parse_control_state(payload),
         {:ok, _session} <-
           WorkerSessions.set_control_state(worker_id, control_state, active_video_id) do
      socket =
        if control_state == :stopped do
          assign(socket, :current_video_id, nil)
        else
          assign(socket, :current_video_id, active_video_id || socket.assigns[:current_video_id])
        end

      {:reply, {:ok, %{accepted: true, state: Atom.to_string(control_state)}}, socket}
    else
      {:error, reason} -> {:reply, {:error, WorkerProtocol.error(reason)}, socket}
    end
  end

  def handle_in("request_work", payload, socket), do: handle_work_request(payload, socket)

  def handle_in("pull_work", payload, socket), do: handle_work_request(payload, socket)

  def handle_in("transfer_progress", payload, socket),
    do: handle_transfer_progress(payload, socket)

  def handle_in("crf_search_progress", payload, socket),
    do: handle_crf_search_progress(payload, socket)

  def handle_in("crf_search_result", payload, socket),
    do: handle_crf_search_result(payload, socket)

  def handle_in("crf_search_completed", payload, socket),
    do: handle_crf_search_completed(payload, socket)

  def handle_in("video_failed", payload, socket),
    do: handle_video_failed(payload, socket)

  def handle_in(_event, _payload, socket) do
    {:reply, {:error, WorkerProtocol.error(:unsupported_event)}, socket}
  end

  @impl true
  def handle_info(:stream_transfer_chunk, %{assigns: %{transfer_io_device: nil}} = socket) do
    case open_transfer_stream(socket) do
      {:ok, socket} ->
        push_transfer_start(socket)

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  def handle_info({:worker_control, action}, socket) do
    push(socket, "control", %{
      action: Atom.to_string(action),
      video_id: socket.assigns[:current_video_id]
    })

    {:noreply, socket}
  end

  def handle_info(:stream_transfer_chunk, %{assigns: %{transfer_io_device: io_device}} = socket)
      when not is_nil(io_device) do
    read_transfer_chunk(socket, io_device)
  end

  def handle_info(:complete_transfer, %{assigns: %{transfer_io_device: io_device}} = socket)
      when not is_nil(io_device) do
    case Media.get_video(socket.assigns.current_video_id) do
      %Media.Video{} = video ->
        {:noreply, complete_transfer(socket, video, io_device)}

      nil ->
        close_transfer_stream(io_device)
        {:noreply, clear_assigned_video(socket.assigns.worker_id, socket)}
    end
  end

  defp ensure_supported_protocol_version(protocol_version) do
    if WorkerProtocol.supported_protocol_version?(protocol_version) do
      :ok
    else
      {:error, :unsupported_protocol_version}
    end
  end

  defp local_worker?(socket, hostname) when is_binary(hostname),
    do: socket.assigns[:loopback_peer] == true and hostname == local_hostname()

  defp local_worker?(_socket, _hostname), do: false

  defp local_hostname do
    {:ok, hostname} = :inet.gethostname()
    List.to_string(hostname)
  end

  @impl true
  def terminate(reason, %{assigns: %{worker_id: worker_id}} = socket) do
    if !shutdown_reason?(reason) do
      maybe_requeue_active_video(socket)
    end

    WorkerSessions.unregister(worker_id)
    :ok
  end

  defp handle_work_request(payload, %{assigns: %{worker_id: worker_id}} = socket) do
    _ = WorkerSessions.touch(worker_id)

    request_mode = work_request_mode(payload)

    case socket.assigns[:current_video_id] do
      nil ->
        resume_or_claim_work(worker_id, socket, request_mode)

      video_id ->
        handle_active_video_work_request(worker_id, socket, video_id, request_mode)
    end
  end

  defp handle_active_video_work_request(worker_id, socket, video_id, request_mode) do
    case Media.get_video(video_id) do
      %Media.Video{state: :crf_searching} = video ->
        request_mode =
          case WorkerSessions.get(worker_id) do
            %{active_video_id: ^video_id} = session ->
              maybe_resume_mode(session, request_mode)

            _ ->
              request_mode
          end

        reply_for_active_work(worker_id, socket, video, request_mode)

      %Media.Video{} ->
        socket = clear_assigned_video(worker_id, socket)
        resume_or_claim_work(worker_id, socket, request_mode)

      nil ->
        {:reply, {:error, WorkerProtocol.error(:unknown_worker_session)}, socket}
    end
  end

  defp resume_or_claim_work(worker_id, socket, request_mode) do
    case resume_session_work(worker_id, socket, request_mode) do
      {:reply, reply, socket} ->
        {:reply, reply, socket}

      :none ->
        case resume_dispatched_work(worker_id, socket, request_mode) do
          {:reply, reply, socket} -> {:reply, reply, socket}
          :none -> claim_work(worker_id, socket)
        end
    end
  end

  defp resume_session_work(worker_id, socket, request_mode) do
    case WorkerSessions.get(worker_id) do
      %{active_video_id: video_id} = session when is_integer(video_id) ->
        with {:ok, socket} <- ensure_resumable_active_video(socket, video_id),
             %Media.Video{} = video <- Media.get_video(video_id) do
          session
          |> maybe_resume_mode(request_mode)
          |> then(&reply_for_active_work(worker_id, socket, video, &1))
        else
          _ -> :none
        end

      _session ->
        :none
    end
  end

  defp maybe_resume_mode(
         %{phase: :receiving_input, transfer_progress: transfer_progress},
         request_mode
       ) do
    if should_resend_transfer?(transfer_progress),
      do: :resend_input,
      else: request_mode
  end

  defp maybe_resume_mode(%{phase: :crf_searching}, :resend_input), do: :resend_input
  defp maybe_resume_mode(%{phase: :crf_searching}, _request_mode), do: :resume_only
  defp maybe_resume_mode(%{phase: :input_ready}, :resend_input), do: :resend_input
  defp maybe_resume_mode(%{phase: :input_ready}, _request_mode), do: :resume_only
  defp maybe_resume_mode(_session, request_mode), do: request_mode

  defp should_resend_transfer?(nil), do: true

  defp should_resend_transfer?(%{bytes_sent: bytes_sent, total_bytes: total_bytes})
       when is_integer(bytes_sent) and is_integer(total_bytes) and total_bytes > 0 do
    bytes_sent < total_bytes
  end

  defp should_resend_transfer?(%{percent: percent}) when is_number(percent),
    do: percent < 100.0

  defp should_resend_transfer?(%{chunk_index: chunk_index, total_chunks: total_chunks})
       when is_integer(chunk_index) and is_integer(total_chunks) and total_chunks > 0 do
    chunk_index < total_chunks
  end

  defp should_resend_transfer?(_), do: true

  defp attach_announced_work(socket, _client_worker_id, %{active_video_id: video_id})
       when is_integer(video_id) do
    attach_active_video(socket, video_id)
  end

  defp attach_announced_work(socket, _client_worker_id, _session), do: socket

  defp attach_active_video(socket, video_id) do
    case Media.get_video(video_id) do
      %Media.Video{} = video ->
        socket
        |> assign(:current_video_id, video.id)
        |> assign(:current_vmaf_target, Reencodarr.Rules.vmaf_target(video))

      nil ->
        socket
    end
  end

  defp resume_dispatched_work(worker_id, socket, request_mode) do
    case Media.get_worker_crf_searching_video(worker_dispatch_id(socket)) do
      %Media.Video{} = video ->
        resume_dispatched_work(worker_id, socket, video, request_mode)

      nil ->
        :none
    end
  end

  defp resume_dispatched_work(worker_id, socket, video, :resend_input) do
    with {:ok, socket} <- ensure_resumable_active_video(socket, video.id, :receiving_input) do
      reply_for_active_work(worker_id, socket, video, :resend_input)
    end
  end

  defp resume_dispatched_work(worker_id, socket, video, :resume_only) do
    with {:ok, socket} <- ensure_resumable_active_video(socket, video.id, :crf_searching) do
      reply_for_active_work(worker_id, socket, video, :resume_only)
    end
  end

  defp handle_transfer_progress(payload, %{assigns: %{worker_id: worker_id}} = socket) do
    with {:ok, progress} <- WorkerProtocol.parse_transfer_progress(payload),
         :ok <- ensure_active_video(socket, progress.video_id) do
      {progress, socket} = fill_transfer_rate(socket, progress)

      _ = WorkerSessions.record_transfer_progress(worker_id, progress)
      Events.broadcast_event(:transfer_progress, Map.put(progress, :worker_id, worker_id))

      socket = maybe_send_next_transfer_chunk(socket, progress)

      {:reply, {:ok, WorkerProtocol.event_ack("transfer_progress")}, socket}
    else
      {:error, reason} ->
        {:reply, {:error, WorkerProtocol.error(reason)}, socket}
    end
  end

  defp handle_crf_search_progress(payload, socket) do
    with {:ok, progress} <- WorkerProtocol.parse_crf_search_progress(payload),
         {:ok, socket} <- ensure_resumable_active_video(socket, progress.video_id) do
      _ = WorkerSessions.set_crf_search_progress(socket.assigns.worker_id, progress)
      Events.broadcast_event(:crf_search_progress, progress)
      {:reply, {:ok, WorkerProtocol.event_ack("crf_search_progress")}, socket}
    else
      {:error, reason} ->
        {:reply, {:error, WorkerProtocol.error(reason)}, socket}
    end
  end

  defp handle_crf_search_result(payload, socket) do
    case WorkerProtocol.parse_crf_search_result(payload) do
      {:ok, result} ->
        handle_parsed_crf_search_result(socket, result)

      {:error, reason} ->
        {:reply, {:error, WorkerProtocol.error(reason)}, socket}
    end
  end

  defp handle_crf_search_completed(payload, %{assigns: %{worker_id: worker_id}} = socket) do
    case WorkerProtocol.parse_completion(payload) do
      {:ok, completion} ->
        handle_parsed_crf_search_completed(worker_id, socket, completion)

      {:error, reason} ->
        {:reply, {:error, WorkerProtocol.error(reason)}, socket}
    end
  end

  defp handle_video_failed(payload, %{assigns: %{worker_id: worker_id}} = socket) do
    with {:ok, failure} <- WorkerProtocol.parse_failure_report(payload),
         {:ok, socket} <- ensure_resumable_active_video(socket, failure.video_id) do
      video = Media.get_video(failure.video_id)

      if is_nil(video) do
        {:reply, {:error, WorkerProtocol.error(:unknown_worker_session)}, socket}
      else
        _ =
          Media.record_video_failure(video, failure.stage, failure.category,
            code: failure.code,
            message: failure.message,
            context: Map.put(failure.context, :stderr_excerpt, failure.stderr_excerpt)
          )

        socket = clear_assigned_video(worker_id, socket)
        Events.broadcast_event(:video_failed, failure)
        {:reply, {:ok, WorkerProtocol.event_ack("video_failed")}, socket}
      end
    else
      {:error, reason} ->
        {:reply, {:error, WorkerProtocol.error(reason)}, socket}
    end
  end

  defp claim_work(worker_id, socket) do
    case Media.claim_next_video_for_crf_search() do
      %Media.Video{} = video ->
        assign_claimed_work(worker_id, socket, video)

      nil ->
        {:reply, {:ok, WorkerProtocol.no_work()}, socket}
    end
  end

  defp assign_claimed_work(worker_id, socket, video) do
    target_vmaf = Reencodarr.Rules.vmaf_target(video)
    local? = local_source?(socket, video)

    with {:ok, _video} <- Media.mark_as_worker_crf_searching(video, worker_dispatch_id(socket)),
         {:ok, video} <- refresh_transfer_source(video, socket.assigns[:local_worker]),
         {:ok, _session} <- WorkerSessions.assign_video(worker_id, video.id, worker_phase(local?)) do
      socket =
        prepare_transfer(socket, video, target_vmaf,
          stream?: not local? and websocket_transfer_on_assign?()
        )

      {:reply, {:ok, WorkerProtocol.work_assigned(video, target_vmaf, local?: local?)}, socket}
    else
      {:error, :source_missing} ->
        fail_missing_source(video)
        {:reply, {:error, WorkerProtocol.error(:source_missing)}, socket}

      {:error, reason} ->
        _ = Media.mark_as_analyzed(video)
        {:reply, {:error, WorkerProtocol.error(reason)}, socket}
    end
  end

  defp reply_for_active_work(worker_id, socket, video, :resend_input) do
    target_vmaf = socket.assigns[:current_vmaf_target] || Reencodarr.Rules.vmaf_target(video)
    local? = local_source?(socket, video)

    with {:ok, video} <- refresh_transfer_source(video, socket.assigns[:local_worker]),
         {:ok, _session} <- WorkerSessions.assign_video(worker_id, video.id, worker_phase(local?)) do
      socket =
        prepare_transfer(socket, video, target_vmaf,
          stream?: not local? and websocket_transfer_on_assign?(),
          fail_if_missing?: true
        )

      {:reply, {:ok, WorkerProtocol.work_assigned(video, target_vmaf, local?: local?)}, socket}
    else
      {:error, :source_missing} ->
        fail_missing_source(video)
        {:reply, {:error, WorkerProtocol.error(:source_missing)}, socket}

      {:error, reason} ->
        {:reply, {:error, WorkerProtocol.error(reason)}, socket}
    end
  end

  defp reply_for_active_work(_worker_id, socket, video, :resume_only) do
    resume_active_work(socket, video)
  end

  defp resume_active_work(socket, video) do
    case refresh_transfer_source(video, socket.assigns[:local_worker]) do
      {:ok, video} ->
        local? = local_source?(socket, video)

        {:reply,
         {:ok,
          WorkerProtocol.work_in_progress(video, socket.assigns[:current_vmaf_target],
            local?: local?
          )}, socket}

      {:error, :source_missing} ->
        fail_missing_source(video)
        {:reply, {:error, WorkerProtocol.error(:source_missing)}, socket}
    end
  end

  defp worker_phase(true), do: :input_ready
  defp worker_phase(false), do: :receiving_input

  defp local_source?(socket, video),
    do: (socket.assigns[:local_worker] || false) and File.regular?(video.path)

  defp prepare_transfer(socket, video, target_vmaf, opts) do
    transfer_id = Integer.to_string(video.id)
    total_bytes = video.size || 0
    chunk_size_bytes = WorkerProtocol.chunk_size_bytes()
    total_chunks = total_chunks(total_bytes, chunk_size_bytes)

    socket =
      socket
      |> assign(:current_video_id, video.id)
      |> assign(:current_vmaf_target, target_vmaf)
      |> assign(:transfer_io_device, nil)
      |> assign(:transfer_path, video.path)
      |> assign(:transfer_id, transfer_id)
      |> assign(:transfer_chunk_size_bytes, chunk_size_bytes)
      |> assign(:transfer_total_bytes, total_bytes)
      |> assign(:transfer_total_chunks, total_chunks)
      |> assign(:transfer_bytes_sent, 0)
      |> assign(:transfer_chunk_index, 0)
      |> assign(:transfer_waiting_for_ack, false)
      |> assign(:transfer_started_sent, nil)
      |> assign(:transfer_complete_pending, nil)
      |> assign(:transfer_last_progress_at, nil)
      |> assign(:transfer_last_progress_bytes, nil)

    if Keyword.get(opts, :stream?, true) and
         (File.exists?(video.path) or Keyword.get(opts, :fail_if_missing?, false)) do
      send(self(), :stream_transfer_chunk)
    end

    socket
  end

  defp refresh_transfer_source(video, local_worker?) do
    case File.stat(video.path) do
      {:ok, %{size: size}} when size != video.size ->
        Logger.warning(
          "Worker transfer size mismatch for video #{video.id}; updating source size"
        )

        case Media.update_video(video, %{size: size}) do
          {:ok, updated_video} -> {:ok, updated_video}
          {:error, _reason} -> {:ok, %{video | size: size}}
        end

      {:ok, _stat} ->
        {:ok, video}

      {:error, :enoent} when local_worker? ->
        {:error, :source_missing}

      {:error, _reason} ->
        {:ok, video}
    end
  end

  defp fail_missing_source(video) do
    Media.record_video_failure(video, :crf_search, :file_access,
      message: "source file no longer exists on server",
      context: %{path: video.path}
    )
  end

  defp websocket_transfer_on_assign?,
    do: is_nil(WorkerConfig.transfer_base_url())

  defp work_request_mode(payload) when is_map(payload) do
    if Enum.any?(
         [
           "input_missing",
           :input_missing,
           "needs_input",
           :needs_input,
           "request_transfer",
           :request_transfer,
           "resend_input",
           :resend_input
         ],
         &truthy?(Map.get(payload, &1))
       ) do
      :resend_input
    else
      :resume_only
    end
  end

  defp work_request_mode(_payload), do: :resume_only

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(1), do: true
  defp truthy?(_value), do: false

  defp maybe_requeue_active_video(socket) do
    case socket.assigns[:current_video_id] do
      nil ->
        :ok

      video_id ->
        case Media.get_video(video_id) do
          %Media.Video{state: :crf_searching, crf_search_worker_id: dispatch_id}
          when is_binary(dispatch_id) ->
            :ok

          %Media.Video{state: :crf_searching} = video ->
            _ = Media.mark_as_analyzed(video)
            :ok

          _ ->
            :ok
        end
    end
  end

  defp handle_valid_crf_search_result(socket, %{video_id: video_id, results: results}) do
    case Media.get_video(video_id) do
      nil ->
        {:reply, {:error, WorkerProtocol.error(:unknown_worker_session)}, socket}

      video ->
        mark_crf_search_active(socket.assigns.worker_id, video_id)

        case persist_crf_results(video, results) do
          {:ok, persisted_results} ->
            reply_after_persisted_crf_results(socket, video, persisted_results)

          {:error, reason} ->
            {:reply, {:error, WorkerProtocol.error(reason)}, socket}
        end
    end
  end

  defp reply_after_persisted_crf_results(socket, video, persisted_results) do
    if Enum.any?(persisted_results, &Map.get(&1, :chosen, false)) do
      finalize_chosen_result_from_report(
        socket.assigns.worker_id,
        socket,
        video,
        persisted_results
      )
    else
      {:reply, {:ok, WorkerProtocol.event_ack("crf_search_result")}, socket}
    end
  end

  defp handle_parsed_crf_search_result(%{assigns: %{worker_id: worker_id}} = socket, result) do
    case Media.get_video(result.video_id) do
      %Media.Video{state: :crf_searched, chosen_vmaf_id: chosen_vmaf_id}
      when not is_nil(chosen_vmaf_id) ->
        {:reply, {:ok, WorkerProtocol.event_ack("crf_search_result")},
         clear_assigned_video(worker_id, socket)}

      _ ->
        case ensure_result_video(socket, result.video_id) do
          {:ok, socket} ->
            handle_valid_crf_search_result(socket, result)

          {:error, reason} ->
            {:reply, {:error, WorkerProtocol.error(reason)}, socket}
        end
    end
  end

  defp handle_valid_crf_search_completion(worker_id, socket, completion) do
    case Media.get_video(completion.video_id) do
      nil ->
        {:reply, {:error, WorkerProtocol.error(:unknown_worker_session)}, socket}

      %Media.Video{state: :crf_searched, chosen_vmaf_id: chosen_vmaf_id}
      when not is_nil(chosen_vmaf_id) ->
        {:reply, {:ok, WorkerProtocol.event_ack("crf_search_completed")},
         clear_assigned_video(worker_id, socket)}

      video ->
        mark_crf_search_active(worker_id, completion.video_id)

        case apply_completion_result(
               worker_id,
               socket,
               video,
               completion.result,
               completion.chosen_crf,
               completion.results
             ) do
          {:ok, socket} ->
            Events.broadcast_event(:crf_search_completed, %{
              video_id: completion.video_id,
              result: completion.result,
              chosen_crf: completion.chosen_crf
            })

            {:reply, {:ok, WorkerProtocol.event_ack("crf_search_completed")}, socket}

          {:error, reason, socket} ->
            {:reply, {:error, WorkerProtocol.error(reason)}, socket}
        end
    end
  end

  defp handle_parsed_crf_search_completed(worker_id, socket, completion) do
    case Media.get_video(completion.video_id) do
      %Media.Video{state: :crf_searched, chosen_vmaf_id: chosen_vmaf_id}
      when not is_nil(chosen_vmaf_id) ->
        {:reply, {:ok, WorkerProtocol.event_ack("crf_search_completed")},
         clear_assigned_video(worker_id, socket)}

      _ ->
        case ensure_result_video(socket, completion.video_id) do
          {:ok, socket} ->
            handle_valid_crf_search_completion(worker_id, socket, completion)

          {:error, reason} ->
            {:reply, {:error, WorkerProtocol.error(reason)}, socket}
        end
    end
  end

  defp apply_completion_result(worker_id, socket, video, :ok, chosen_crf, results) do
    case persist_crf_results(video, results) do
      {:ok, persisted_results} ->
        chosen_crf = chosen_crf || chosen_crf_from_results(persisted_results)
        finish_successful_crf_search(worker_id, socket, video, chosen_crf)

      {:error, reason} ->
        fail_invalid_successful_crf_search(worker_id, socket, video, reason)
    end
  end

  defp apply_completion_result(worker_id, socket, video, :cancelled, _chosen_crf, _results) do
    finish_cancelled_crf_search(worker_id, socket, video, :cancelled)
  end

  defp apply_completion_result(worker_id, socket, video, :shutdown, _chosen_crf, _results) do
    finish_cancelled_crf_search(worker_id, socket, video, :shutdown)
  end

  defp apply_completion_result(worker_id, socket, video, :failed, _chosen_crf, _results) do
    record_completion_failure(worker_id, socket, video, "failed")
  end

  defp apply_completion_result(worker_id, socket, video, {:error, reason}, _chosen_crf, _results) do
    record_completion_failure(worker_id, socket, video, inspect(reason))
  end

  defp record_completion_failure(worker_id, socket, video, code) do
    _ =
      Media.record_video_failure(video, :crf_search, :crf_optimization,
        code: code,
        message: "CRF search failed"
      )

    _ = Media.mark_as_failed(video)
    {:ok, clear_assigned_video(worker_id, socket)}
  end

  defp ensure_active_video(socket, video_id) do
    case socket.assigns[:current_video_id] do
      nil -> {:error, :unknown_worker_session}
      ^video_id -> :ok
      _other -> {:error, :unknown_worker_session}
    end
  end

  defp ensure_resumable_active_video(socket, video_id, phase \\ :crf_searching) do
    case socket.assigns[:current_video_id] do
      ^video_id ->
        {:ok, socket}

      nil ->
        resume_active_video(socket, video_id, phase)

      _other ->
        {:error, :unknown_worker_session}
    end
  end

  defp ensure_result_video(socket, video_id) do
    case ensure_resumable_active_video(socket, video_id) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, :unknown_worker_session} ->
        allow_dispatched_video_result(socket, video_id)
    end
  end

  defp allow_dispatched_video_result(socket, video_id) do
    case Media.get_video(video_id) do
      %Media.Video{state: :crf_searching, crf_search_worker_id: dispatch_id} = video
      when is_binary(dispatch_id) ->
        {:ok,
         socket
         |> assign(:current_video_id, video.id)
         |> assign(:current_vmaf_target, Reencodarr.Rules.vmaf_target(video))}

      _ ->
        {:error, :unknown_worker_session}
    end
  end

  defp resume_active_video(
         %{assigns: %{worker_id: worker_id}} = socket,
         video_id,
         phase
       ) do
    with %Media.Video{state: :crf_searching, crf_search_worker_id: dispatch_id} = video
         when is_binary(dispatch_id) <- Media.get_video(video_id),
         true <- dispatch_id == worker_dispatch_id(socket),
         false <- assigned_to_other_worker?(worker_id, video_id),
         {:ok, _session} <- WorkerSessions.assign_video(worker_id, video_id, phase) do
      {:ok,
       socket
       |> assign(:current_video_id, video_id)
       |> assign(:current_vmaf_target, Reencodarr.Rules.vmaf_target(video))}
    else
      _ -> {:error, :unknown_worker_session}
    end
  end

  defp assigned_to_other_worker?(worker_id, video_id) do
    WorkerSessions.list()
    |> Enum.any?(&(&1.server_worker_id != worker_id and &1.active_video_id == video_id))
  end

  defp shutdown_reason?(:shutdown), do: true
  defp shutdown_reason?({:shutdown, _reason}), do: true
  defp shutdown_reason?(_reason), do: false

  defp worker_dispatch_id(socket),
    do: socket.assigns[:client_worker_id] || socket.assigns.worker_id

  defp persist_crf_results(video, results) do
    Enum.reduce_while(results, {:ok, []}, fn result, {:ok, acc} ->
      params = CrfSearch.build_crf_search_args(video, result_target(video, result))

      attrs =
        result
        |> Map.put(:video_id, video.id)
        |> Map.update(:params, params, fn
          [] -> params
          nil -> params
          existing_params -> existing_params
        end)
        |> Map.delete(:chosen)

      case Media.upsert_vmaf(attrs) do
        {:ok, :skipped} ->
          {:cont, {:ok, [result | acc]}}

        {:ok, vmaf} ->
          Events.broadcast_event(:crf_search_vmaf_result, vmaf_to_event(vmaf))
          {:cont, {:ok, [result | acc]}}

        {:error, _reason} ->
          {:halt, {:error, :invalid_crf_search_result}}
      end
    end)
    |> case do
      {:ok, persisted_results} -> {:ok, Enum.reverse(persisted_results)}
      {:error, _reason} = error -> error
    end
  end

  defp result_target(video, result),
    do: Map.get(result, :target) || Reencodarr.Rules.vmaf_target(video)

  defp finalize_chosen_result_from_report(worker_id, socket, video, results) do
    chosen_crf = chosen_crf_from_results(results)

    case chosen_crf do
      nil ->
        {:reply, {:ok, WorkerProtocol.event_ack("crf_search_result")}, socket}

      crf ->
        mark_reported_chosen_crf(worker_id, socket, video, crf)
    end
  end

  defp chosen_crf_from_results(results) do
    Enum.find_value(results, fn result ->
      if Map.get(result, :chosen, false), do: Map.get(result, :crf)
    end)
  end

  defp mark_reported_chosen_crf(worker_id, socket, video, crf) do
    case Media.mark_vmaf_as_chosen(video.id, crf) do
      {:ok, _} ->
        reply_after_successful_crf_search_result(worker_id, socket, video)

      {:error, _reason} ->
        _ =
          Media.record_video_failure(video, :crf_search, :validation,
            code: "no_chosen_vmaf",
            message: "CRF search reported a chosen CRF but no matching VMAF row was found",
            context: %{video_id: video.id, chosen_crf: crf}
          )

        _ = Media.mark_as_failed(video)

        {:reply, {:error, WorkerProtocol.error(:invalid_crf_search_result)},
         clear_assigned_video(worker_id, socket)}
    end
  end

  defp reply_after_successful_crf_search_result(worker_id, socket, video) do
    case finalize_successful_crf_search(worker_id, socket, video) do
      {:ok, socket} ->
        {:reply, {:ok, WorkerProtocol.event_ack("crf_search_result")}, socket}

      {:error, reason, socket} ->
        {:reply, {:error, WorkerProtocol.error(reason)}, socket}
    end
  end

  defp finish_successful_crf_search(worker_id, socket, video, chosen_crf) do
    cond do
      is_number(chosen_crf) ->
        case Media.mark_vmaf_as_chosen(video.id, chosen_crf) do
          {:ok, _vmaf_id} ->
            finalize_successful_crf_search(worker_id, socket, video)

          {:error, reason} ->
            fail_invalid_successful_crf_search(worker_id, socket, video, reason)
        end

      Media.chosen_vmaf_exists?(video) ->
        finalize_successful_crf_search(worker_id, socket, video)

      true ->
        fail_invalid_successful_crf_search(worker_id, socket, video, :no_chosen_vmaf)
    end
  end

  defp finalize_successful_crf_search(worker_id, socket, video) do
    case Media.mark_as_crf_searched(video) do
      {:ok, _video} ->
        _ = Media.resolve_crf_search_failures(video.id)
        {:ok, clear_assigned_video(worker_id, socket)}

      {:error, reason} ->
        fail_invalid_successful_crf_search(worker_id, socket, video, reason)
    end
  end

  defp fail_invalid_successful_crf_search(worker_id, socket, video, reason) do
    _ =
      Media.record_video_failure(video, :crf_search, :validation,
        code: "invalid_successful_crf_search",
        message: "CRF search completed successfully but could not choose a VMAF",
        context: %{video_id: video.id, reason: inspect(reason)}
      )

    _ = Media.mark_as_failed(video)
    {:error, :invalid_crf_search_result, clear_assigned_video(worker_id, socket)}
  end

  defp finish_cancelled_crf_search(worker_id, socket, video, _reason) do
    _ = Media.mark_as_analyzed(video)
    {:ok, clear_assigned_video(worker_id, socket)}
  end

  defp clear_assigned_video(worker_id, socket) do
    _ = WorkerSessions.clear_video(worker_id)

    assign(socket, :current_video_id, nil)
    |> assign(:current_vmaf_target, nil)
    |> assign(:transfer_io_device, nil)
    |> assign(:transfer_path, nil)
    |> assign(:transfer_id, nil)
    |> assign(:transfer_chunk_size_bytes, nil)
    |> assign(:transfer_total_bytes, nil)
    |> assign(:transfer_total_chunks, nil)
    |> assign(:transfer_bytes_sent, nil)
    |> assign(:transfer_chunk_index, nil)
    |> assign(:transfer_waiting_for_ack, nil)
    |> assign(:transfer_started_sent, nil)
    |> assign(:transfer_complete_pending, nil)
    |> assign(:transfer_last_progress_at, nil)
    |> assign(:transfer_last_progress_bytes, nil)
  end

  defp mark_crf_search_active(worker_id, video_id) do
    _ = WorkerSessions.set_crf_search_progress(worker_id, %{video_id: video_id})
    :ok
  end

  defp open_transfer_stream(
         %{assigns: %{current_video_id: video_id, transfer_path: path}} = socket
       ) do
    case File.open(path, [:read, :binary]) do
      {:ok, io_device} ->
        socket =
          socket
          |> assign(:transfer_io_device, io_device)
          |> assign(:transfer_started_sent, false)
          |> assign(:transfer_complete_pending, false)
          |> assign(:transfer_last_progress_at, nil)
          |> assign(:transfer_last_progress_bytes, nil)

        {:ok, socket}

      {:error, reason} ->
        socket = handle_transfer_failure(socket, video_id, reason)
        {:error, socket}
    end
  end

  defp push_transfer_start(%{assigns: %{current_video_id: video_id}} = socket) do
    video = Media.get_video(video_id)

    if is_nil(video) do
      {:noreply, handle_transfer_failure(socket, video_id, :enoent)}
    else
      _ =
        WorkerSessions.record_transfer_progress(
          socket.assigns.worker_id,
          initial_transfer_progress(socket, video)
        )

      socket =
        socket
        |> assign(:transfer_started_sent, true)

      push(
        socket,
        "transfer_started",
        WorkerProtocol.transfer_started(
          video,
          socket.assigns.transfer_id,
          socket.assigns.transfer_chunk_size_bytes,
          socket.assigns.transfer_total_bytes,
          socket.assigns.transfer_total_chunks
        )
      )

      send(self(), :stream_transfer_chunk)
      {:noreply, socket}
    end
  end

  defp initial_transfer_progress(socket, video) do
    %WorkerProtocol.TransferProgress{
      job_id: socket.assigns.transfer_id,
      video_id: video.id,
      transfer_id: socket.assigns.transfer_id,
      filename: Path.basename(video.path),
      percent: 0.0,
      bytes_sent: 0,
      total_bytes: socket.assigns.transfer_total_bytes,
      bytes_per_second: nil,
      eta: nil,
      chunk_index: 0,
      total_chunks: socket.assigns.transfer_total_chunks
    }
  end

  defp read_transfer_chunk(%{assigns: %{current_video_id: video_id}} = socket, io_device) do
    video = Media.get_video(video_id)

    if is_nil(video) do
      close_transfer_stream(io_device)
      {:noreply, socket}
    else
      case IO.binread(io_device, socket.assigns.transfer_chunk_size_bytes) do
        chunk when is_binary(chunk) ->
          chunk_index = socket.assigns.transfer_chunk_index
          bytes_sent = socket.assigns.transfer_bytes_sent + byte_size(chunk)

          push(
            socket,
            "transfer_chunk",
            WorkerProtocol.transfer_chunk(
              video,
              socket.assigns.transfer_id,
              chunk_index,
              socket.assigns.transfer_total_chunks,
              bytes_sent,
              socket.assigns.transfer_total_bytes,
              chunk
            )
          )

          {:noreply,
           socket
           |> assign(:transfer_bytes_sent, bytes_sent)
           |> assign(:transfer_chunk_index, chunk_index + 1)
           |> assign(:transfer_waiting_for_ack, true)
           |> assign(
             :transfer_complete_pending,
             bytes_sent >= socket.assigns.transfer_total_bytes
           )}

        :eof ->
          {:noreply, complete_transfer(socket, video, io_device)}

        {:error, reason} ->
          close_transfer_stream(io_device)
          {:noreply, handle_transfer_failure(socket, video_id, reason)}
      end
    end
  end

  defp complete_transfer(socket, video, io_device) do
    close_transfer_stream(io_device)

    push(
      socket,
      "transfer_complete",
      WorkerProtocol.transfer_complete(
        video,
        socket.assigns.transfer_id,
        socket.assigns.transfer_total_bytes,
        socket.assigns.transfer_total_chunks
      )
    )

    socket
    |> assign(:transfer_io_device, nil)
    |> assign(:transfer_path, nil)
    |> assign(:transfer_id, nil)
    |> assign(:transfer_chunk_size_bytes, nil)
    |> assign(:transfer_total_bytes, nil)
    |> assign(:transfer_total_chunks, nil)
    |> assign(:transfer_bytes_sent, nil)
    |> assign(:transfer_chunk_index, nil)
    |> assign(:transfer_waiting_for_ack, nil)
    |> assign(:transfer_started_sent, nil)
    |> assign(:transfer_complete_pending, nil)
    |> assign(:transfer_last_progress_at, nil)
    |> assign(:transfer_last_progress_bytes, nil)
  end

  defp fill_transfer_rate(socket, progress) do
    now = System.monotonic_time(:millisecond)

    progress =
      progress
      |> maybe_fill_bytes_per_second(socket, now)
      |> maybe_fill_eta()

    socket =
      socket
      |> assign(:transfer_last_progress_at, now)
      |> assign(:transfer_last_progress_bytes, progress.bytes_sent)

    {progress, socket}
  end

  defp maybe_fill_bytes_per_second(%{bytes_per_second: rate} = progress, _socket, _now)
       when is_integer(rate) and rate >= 0,
       do: progress

  defp maybe_fill_bytes_per_second(
         %{bytes_sent: bytes_sent} = progress,
         %{
           assigns: %{
             transfer_last_progress_at: last_at,
             transfer_last_progress_bytes: last_bytes
           }
         },
         now
       )
       when is_integer(bytes_sent) and is_integer(last_bytes) and is_integer(last_at) and
              bytes_sent >= last_bytes and now > last_at do
    elapsed_ms = now - last_at
    bytes_delta = bytes_sent - last_bytes

    if bytes_delta > 0 do
      %{progress | bytes_per_second: div(bytes_delta * 1_000, elapsed_ms)}
    else
      progress
    end
  end

  defp maybe_fill_bytes_per_second(progress, _socket, _now), do: progress

  defp maybe_fill_eta(%{eta: eta} = progress) when is_integer(eta) and eta >= 0,
    do: progress

  defp maybe_fill_eta(%{bytes_per_second: rate, bytes_sent: sent, total_bytes: total} = progress)
       when is_integer(rate) and rate > 0 and is_integer(sent) and is_integer(total) and
              total > sent do
    %{progress | eta: ceil((total - sent) / rate)}
  end

  defp maybe_fill_eta(progress), do: progress

  defp handle_transfer_failure(socket, video_id, reason) do
    case Media.get_video(video_id) do
      nil ->
        clear_assigned_video(socket.assigns.worker_id, socket)

      video ->
        message = format_file_error(reason)

        _ =
          Media.record_video_failure(video, :crf_search, :file_access,
            message: "Transfer failed: #{message}",
            context: %{
              transfer_id: socket.assigns[:transfer_id],
              path: socket.assigns[:transfer_path]
            }
          )

        socket = clear_assigned_video(socket.assigns.worker_id, socket)

        _ =
          push(
            socket,
            "transfer_failed",
            WorkerProtocol.transfer_failed(video, Integer.to_string(video.id), message)
          )

        socket
    end
  end

  defp close_transfer_stream(nil), do: :ok
  defp close_transfer_stream(io_device), do: File.close(io_device)

  defp maybe_send_next_transfer_chunk(
         %{
           assigns: %{
             transfer_id: transfer_id,
             transfer_bytes_sent: bytes_sent,
             transfer_waiting_for_ack: true,
             transfer_complete_pending: complete_pending?
           }
         } = socket,
         %{transfer_id: transfer_id, bytes_sent: acknowledged_bytes}
       )
       when is_integer(bytes_sent) and is_integer(acknowledged_bytes) and
              acknowledged_bytes >= bytes_sent do
    if complete_pending? do
      send(self(), :complete_transfer)
    else
      send(self(), :stream_transfer_chunk)
    end

    assign(socket, :transfer_waiting_for_ack, false)
  end

  defp maybe_send_next_transfer_chunk(socket, _progress), do: socket

  defp format_file_error(reason) do
    reason |> :file.format_error() |> List.to_string()
  end

  defp total_chunks(0, _chunk_size_bytes), do: 0

  defp total_chunks(total_bytes, chunk_size_bytes),
    do: div(total_bytes + chunk_size_bytes - 1, chunk_size_bytes)

  defp vmaf_to_event(%Reencodarr.Media.Vmaf{} = vmaf) do
    %{
      video_id: vmaf.video_id,
      crf: vmaf.crf,
      score: vmaf.score,
      percent: vmaf.percent,
      size: vmaf.size,
      time: vmaf.time,
      params: vmaf.params || []
    }
  end
end
