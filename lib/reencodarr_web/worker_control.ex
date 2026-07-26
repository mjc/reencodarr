defmodule ReencodarrWeb.WorkerControl do
  @moduledoc false

  @events %{
    "pause_worker_crf_search" => {:pause, "Worker pause requested", :job},
    "resume_worker_crf_search" => {:resume, "Worker resume requested", :job},
    "stop_worker_crf_search" => {:stop, "Worker stop requested", :job},
    "start_worker_crf_search" => {:start, "Worker start requested", :worker},
    "pause_worker_encode" => {:pause, "Worker encode pause requested", :job},
    "resume_worker_encode" => {:resume, "Worker encode resume requested", :job},
    "stop_worker_encode" => {:stop, "Worker encode stop requested", :job}
  }

  @event_names Map.keys(@events)

  @spec event_names() :: [String.t()]
  def event_names, do: @event_names

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event(event, params, socket) do
    with {:ok, {action, message, scope}} <- Map.fetch(@events, event),
         {:ok, worker_id} <- fetch_id(params, "worker-id"),
         {:ok, job_id} <- fetch_job_id(scope, params) do
      command =
        if job_id, do: {:worker_control, action, job_id}, else: {:worker_control, action}

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        ReencodarrWeb.WorkerChannel.worker_control_topic(worker_id),
        command
      )

      {:noreply, Phoenix.LiveView.put_flash(socket, :info, message)}
    else
      _ ->
        {:noreply,
         Phoenix.LiveView.put_flash(socket, :error, "Worker job is no longer available")}
    end
  end

  defp fetch_job_id(:worker, _params), do: {:ok, nil}
  defp fetch_job_id(:job, params), do: fetch_id(params, "job-id")

  defp fetch_id(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  end
end
