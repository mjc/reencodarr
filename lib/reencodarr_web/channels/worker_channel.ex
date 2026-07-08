defmodule ReencodarrWeb.WorkerChannel do
  @moduledoc """
  Phoenix channel for long-lived ab-av1 CRF-search workers.
  """

  use ReencodarrWeb, :channel

  alias Reencodarr.AbAv1.{WorkerProtocol, WorkerSessions}
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
            protocol_version: protocol_version,
            version: version,
            capabilities: capabilities
          }} <- WorkerProtocol.parse_announcement(payload),
         :ok <- ensure_supported_protocol_version(protocol_version),
         {:ok, _session} <-
           WorkerSessions.register(%{
             server_worker_id: server_worker_id,
             client_worker_id: client_worker_id,
             protocol_version: protocol_version,
             version: version,
             capabilities: capabilities
           }) do
      socket =
        socket
        |> assign(:client_worker_id, client_worker_id)
        |> assign(:client_version, version)
        |> assign(:protocol_version, protocol_version)
        |> assign(:capabilities, capabilities)

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

  defp ensure_supported_protocol_version(protocol_version) do
    if WorkerProtocol.supported_protocol_version?(protocol_version) do
      :ok
    else
      {:error, :unsupported_protocol_version}
    end
  end

  @impl true
  def terminate(reason, %{assigns: %{worker_id: worker_id}} = socket) do
    if !shutdown_reason?(reason) do
      maybe_requeue_active_video(socket)
    end

    WorkerSessions.unregister(worker_id)
    :ok
  end

  defp handle_work_request(_payload, %{assigns: %{worker_id: worker_id}} = socket) do
    case socket.assigns[:current_video_id] do
      nil ->
        case resume_dispatched_work(socket) do
          {:reply, reply, socket} -> {:reply, reply, socket}
          :none -> claim_work(worker_id, socket)
        end

      video_id ->
        case Media.get_video(video_id) do
          %Media.Video{} = video ->
            {:reply,
             {:ok, WorkerProtocol.work_in_progress(video, socket.assigns[:current_vmaf_target])},
             socket}

          nil ->
            {:reply, {:error, WorkerProtocol.error(:unknown_worker_session)}, socket}
        end
    end
  end

  defp resume_dispatched_work(socket) do
    case Media.get_worker_crf_searching_video(worker_dispatch_id(socket)) do
      %Media.Video{} = video ->
        with {:ok, socket} <- ensure_resumable_active_video(socket, video.id) do
          {:reply,
           {:ok, WorkerProtocol.work_in_progress(video, socket.assigns[:current_vmaf_target])},
           socket}
        end

      nil ->
        :none
    end
  end

  defp handle_transfer_progress(payload, %{assigns: %{worker_id: worker_id}} = socket) do
    with {:ok, progress} <- WorkerProtocol.parse_transfer_progress(payload),
         :ok <- ensure_active_video(socket, progress.video_id) do
      _ = WorkerSessions.set_transfer_progress(worker_id, progress)
      Events.broadcast_event(:transfer_progress, Map.put(progress, :worker_id, worker_id))
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
    with {:ok, result} <- WorkerProtocol.parse_crf_search_result(payload),
         {:ok, socket} <- ensure_resumable_active_video(socket, result.video_id) do
      handle_valid_crf_search_result(socket, result)
    else
      {:error, reason} ->
        {:reply, {:error, WorkerProtocol.error(reason)}, socket}
    end
  end

  defp handle_crf_search_completed(payload, %{assigns: %{worker_id: worker_id}} = socket) do
    with {:ok, completion} <- WorkerProtocol.parse_completion(payload),
         {:ok, socket} <- ensure_resumable_active_video(socket, completion.video_id) do
      handle_valid_crf_search_completion(worker_id, socket, completion)
    else
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
    transfer_id = Integer.to_string(video.id)
    total_bytes = video.size || 0
    chunk_size_bytes = WorkerProtocol.chunk_size_bytes()
    total_chunks = total_chunks(total_bytes, chunk_size_bytes)

    with {:ok, _video} <- Media.mark_as_worker_crf_searching(video, worker_dispatch_id(socket)),
         {:ok, _session} <- WorkerSessions.assign_video(worker_id, video.id) do
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

      if File.exists?(video.path) do
        send(self(), :stream_transfer_chunk)
      end

      {:reply, {:ok, WorkerProtocol.work_assigned(video, target_vmaf)}, socket}
    else
      {:error, reason} ->
        _ = Media.mark_as_analyzed(video)
        {:reply, {:error, WorkerProtocol.error(reason)}, socket}
    end
  end

  defp maybe_requeue_active_video(socket) do
    case socket.assigns[:current_video_id] do
      nil ->
        :ok

      video_id ->
        case Media.get_video(video_id) do
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
        persist_crf_results(video, results)

        if Enum.any?(results, &Map.get(&1, :chosen, false)) do
          choose_result_from_report(video, results)
        end

        {:reply, {:ok, WorkerProtocol.event_ack("crf_search_result")}, socket}
    end
  end

  defp handle_valid_crf_search_completion(worker_id, socket, completion) do
    case Media.get_video(completion.video_id) do
      nil ->
        {:reply, {:error, WorkerProtocol.error(:unknown_worker_session)}, socket}

      video ->
        socket =
          apply_completion_result(
            worker_id,
            socket,
            video,
            completion.result,
            completion.chosen_crf
          )

        Events.broadcast_event(:crf_search_completed, %{
          video_id: completion.video_id,
          result: completion.result,
          chosen_crf: completion.chosen_crf
        })

        {:reply, {:ok, WorkerProtocol.event_ack("crf_search_completed")}, socket}
    end
  end

  defp apply_completion_result(worker_id, socket, video, :ok, chosen_crf) do
    finish_successful_crf_search(worker_id, socket, video, chosen_crf)
  end

  defp apply_completion_result(worker_id, socket, video, :cancelled, _chosen_crf) do
    finish_cancelled_crf_search(worker_id, socket, video, :cancelled)
  end

  defp apply_completion_result(worker_id, socket, video, :shutdown, _chosen_crf) do
    finish_cancelled_crf_search(worker_id, socket, video, :shutdown)
  end

  defp apply_completion_result(worker_id, socket, video, :failed, _chosen_crf) do
    record_completion_failure(worker_id, socket, video, "failed")
  end

  defp apply_completion_result(worker_id, socket, video, {:error, reason}, _chosen_crf) do
    record_completion_failure(worker_id, socket, video, inspect(reason))
  end

  defp record_completion_failure(worker_id, socket, video, code) do
    _ =
      Media.record_video_failure(video, :crf_search, :crf_optimization,
        code: code,
        message: "CRF search failed"
      )

    clear_assigned_video(worker_id, socket)
  end

  defp ensure_active_video(socket, video_id) do
    case socket.assigns[:current_video_id] do
      nil -> {:error, :unknown_worker_session}
      ^video_id -> :ok
      _other -> {:error, :unknown_worker_session}
    end
  end

  defp ensure_resumable_active_video(socket, video_id) do
    case socket.assigns[:current_video_id] do
      ^video_id ->
        {:ok, socket}

      nil ->
        resume_active_video(socket, video_id)

      _other ->
        {:error, :unknown_worker_session}
    end
  end

  defp resume_active_video(%{assigns: %{worker_id: worker_id}} = socket, video_id) do
    with %Media.Video{state: :crf_searching, crf_search_worker_id: dispatch_id} = video
         when is_binary(dispatch_id) <- Media.get_video(video_id),
         true <- dispatch_id == worker_dispatch_id(socket),
         false <- assigned_to_other_worker?(worker_id, video_id),
         {:ok, _session} <- WorkerSessions.assign_video(worker_id, video_id) do
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
    Enum.each(results, fn result ->
      attrs =
        result
        |> Map.put(:video_id, video.id)
        |> Map.delete(:chosen)

      case Media.upsert_vmaf(attrs) do
        {:ok, :skipped} -> :ok
        {:ok, vmaf} -> Events.broadcast_event(:crf_search_vmaf_result, vmaf_to_event(vmaf))
        {:error, _} -> :ok
      end
    end)
  end

  defp choose_result_from_report(video, results) do
    chosen_crf =
      Enum.find_value(results, fn result ->
        if Map.get(result, :chosen, false), do: Map.get(result, :crf)
      end) || Map.get(List.first(results) || %{}, :crf)

    case chosen_crf do
      nil -> :ok
      crf -> _ = Media.mark_vmaf_as_chosen(video.id, crf)
    end

    _ = Media.mark_as_crf_searched(video)
    _ = Media.resolve_crf_search_failures(video.id)
    :ok
  end

  defp finish_successful_crf_search(worker_id, socket, video, chosen_crf) do
    case chosen_crf do
      nil ->
        case Media.choose_best_vmaf(video) do
          {:ok, _vmaf} -> :ok
          {:error, _} -> :ok
        end

      crf ->
        _ = Media.mark_vmaf_as_chosen(video.id, crf)
    end

    _ = Media.mark_as_crf_searched(video)
    _ = Media.resolve_crf_search_failures(video.id)
    clear_assigned_video(worker_id, socket)
  end

  defp finish_cancelled_crf_search(worker_id, socket, video, _reason) do
    _ = Media.mark_as_analyzed(video)
    clear_assigned_video(worker_id, socket)
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
    |> assign(:transfer_started_sent, nil)
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
        WorkerSessions.set_transfer_progress(
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

          send(self(), :stream_transfer_chunk)

          {:noreply,
           socket
           |> assign(:transfer_bytes_sent, bytes_sent)
           |> assign(:transfer_chunk_index, chunk_index + 1)}

        :eof ->
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

          {:noreply,
           socket
           |> assign(:transfer_io_device, nil)
           |> assign(:transfer_path, nil)
           |> assign(:transfer_id, nil)
           |> assign(:transfer_chunk_size_bytes, nil)
           |> assign(:transfer_total_bytes, nil)
           |> assign(:transfer_total_chunks, nil)
           |> assign(:transfer_bytes_sent, nil)
           |> assign(:transfer_chunk_index, nil)
           |> assign(:transfer_started_sent, nil)}

        {:error, reason} ->
          close_transfer_stream(io_device)
          {:noreply, handle_transfer_failure(socket, video_id, reason)}
      end
    end
  end

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
