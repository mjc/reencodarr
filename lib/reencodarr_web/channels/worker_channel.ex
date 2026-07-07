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

  @impl true
  def join(@crf_search_topic, _payload, %{assigns: %{worker_id: worker_id}} = socket) do
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

  def handle_in("heartbeat", _payload, %{assigns: %{worker_id: worker_id}} = socket) do
    case WorkerSessions.touch(worker_id) do
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

  defp ensure_supported_protocol_version(protocol_version) do
    if WorkerProtocol.supported_protocol_version?(protocol_version) do
      :ok
    else
      {:error, :unsupported_protocol_version}
    end
  end

  @impl true
  def terminate(_reason, %{assigns: %{worker_id: worker_id}} = socket) do
    maybe_requeue_active_video(socket)
    WorkerSessions.unregister(worker_id)
    :ok
  end

  defp handle_work_request(_payload, %{assigns: %{worker_id: worker_id}} = socket) do
    case socket.assigns[:current_video_id] do
      nil ->
        claim_work(worker_id, socket)

      video_id ->
        case Media.get_video(video_id) do
          %Media.Video{} = video ->
            {:reply,
             {:ok, WorkerProtocol.work_assigned(video, socket.assigns[:current_vmaf_target])},
             socket}

          nil ->
            {:reply, {:error, WorkerProtocol.error(:unknown_worker_session)}, socket}
        end
    end
  end

  defp handle_transfer_progress(payload, %{assigns: %{worker_id: worker_id}} = socket) do
    with {:ok, progress} <- WorkerProtocol.parse_transfer_progress(payload),
         :ok <- ensure_active_video(socket, progress.video_id) do
      Events.broadcast_event(:transfer_progress, Map.put(progress, :worker_id, worker_id))
      {:reply, {:ok, WorkerProtocol.event_ack("transfer_progress")}, socket}
    else
      {:error, reason} ->
        {:reply, {:error, WorkerProtocol.error(reason)}, socket}
    end
  end

  defp handle_crf_search_progress(payload, socket) do
    with {:ok, progress} <- WorkerProtocol.parse_crf_search_progress(payload),
         :ok <- ensure_active_video(socket, progress.video_id) do
      Events.broadcast_event(:crf_search_progress, progress)
      {:reply, {:ok, WorkerProtocol.event_ack("crf_search_progress")}, socket}
    else
      {:error, reason} ->
        {:reply, {:error, WorkerProtocol.error(reason)}, socket}
    end
  end

  defp handle_crf_search_result(payload, socket) do
    with {:ok, result} <- WorkerProtocol.parse_crf_search_result(payload),
         :ok <- ensure_active_video(socket, result.video_id) do
      handle_valid_crf_search_result(socket, result)
    else
      {:error, reason} ->
        {:reply, {:error, WorkerProtocol.error(reason)}, socket}
    end
  end

  defp handle_crf_search_completed(payload, %{assigns: %{worker_id: worker_id}} = socket) do
    with {:ok, completion} <- WorkerProtocol.parse_completion(payload),
         :ok <- ensure_active_video(socket, completion.video_id) do
      handle_valid_crf_search_completion(worker_id, socket, completion)
    else
      {:error, reason} ->
        {:reply, {:error, WorkerProtocol.error(reason)}, socket}
    end
  end

  defp handle_video_failed(payload, %{assigns: %{worker_id: worker_id}} = socket) do
    with {:ok, failure} <- WorkerProtocol.parse_failure_report(payload),
         :ok <- ensure_active_video(socket, failure.video_id) do
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

    case WorkerSessions.assign_video(worker_id, video.id) do
      {:ok, _session} ->
        socket =
          socket
          |> assign(:current_video_id, video.id)
          |> assign(:current_vmaf_target, target_vmaf)

        {:reply, {:ok, WorkerProtocol.work_assigned(video, target_vmaf)}, socket}

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
  end

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
