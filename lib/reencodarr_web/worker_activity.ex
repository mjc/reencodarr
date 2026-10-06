defmodule ReencodarrWeb.WorkerActivity do
  @moduledoc false

  alias Reencodarr.AbAv1.WorkerProtocol.CrfSearchProgress
  alias Reencodarr.AbAv1.WorkerSessions
  alias Reencodarr.AbAv1.WorkerSessions.Job
  alias Reencodarr.Media

  @type encode_worker_data :: %{
          optional(pos_integer()) => %{
            video: Reencodarr.Media.Video.t() | nil,
            vmaf: Reencodarr.Media.Vmaf.t() | nil
          }
        }

  @spec load_worker_encode_data([WorkerSessions.session()], encode_worker_data()) ::
          encode_worker_data()
  def load_worker_encode_data(workers, cached \\ %{}) do
    video_ids =
      workers
      |> Enum.flat_map(fn worker ->
        worker.jobs
        |> Map.values()
        |> Enum.filter(&match?(%Job{job_type: :encode, active: true}, &1))
      end)
      |> Enum.map(& &1.video_id)
      |> Enum.uniq()

    Enum.reduce(video_ids, Map.take(cached, video_ids), fn video_id, data ->
      Map.put_new_lazy(data, video_id, fn ->
        video = Media.get_video(video_id)

        %{
          video: video,
          vmaf: video && video.chosen_vmaf_id && Media.get_vmaf!(video.chosen_vmaf_id)
        }
      end)
    end)
  end

  def load_worker_crf_data(workers, cached \\ %{}) do
    video_ids =
      workers
      |> Enum.flat_map(fn worker ->
        jobs =
          Map.get(worker, :jobs, %{})
          |> Map.values()
          |> Enum.filter(&match?(%Job{job_type: :crf_search, active: true}, &1))

        [active_video_id(worker) | Enum.map(jobs, & &1.video_id)]
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.reduce(video_ids, Map.take(cached, video_ids), fn video_id, data ->
      Map.put_new_lazy(data, video_id, fn ->
        %{video: Media.get_video(video_id), results: Media.get_vmafs_for_video(video_id)}
      end)
    end)
  end

  defp active_video_id(%{active_video_id: video_id}) when is_integer(video_id), do: video_id

  defp active_video_id(%{crf_search_progress: %CrfSearchProgress{video_id: video_id}}),
    do: video_id

  defp active_video_id(%{transfer_progress: %{video_id: video_id}}), do: video_id
  defp active_video_id(_worker), do: nil

  @spec label(Job.t() | nil, DateTime.t()) :: String.t() | nil
  def label(job, now \\ DateTime.utc_now())
  def label(nil, _now), do: nil

  def label(%Job{} = job, now) do
    recovery = if job.recovery_action, do: " · #{recovery_label(job.recovery_action)}", else: ""
    "#{phase_label(job.phase)} · last activity #{age_label(job.last_activity_at, now)}#{recovery}"
  end

  defp phase_label(phase),
    do: phase |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  defp recovery_label(:warned), do: "May be stalled"
  defp recovery_label(:stop_requested), do: "Stopping stalled job"
  defp recovery_label(:stale), do: "Replaced attempt"

  defp age_label(nil, _now), do: "unknown"

  defp age_label(activity_at, now) do
    case max(DateTime.diff(now, activity_at, :second), 0) do
      seconds when seconds < 60 -> "#{seconds}s ago"
      seconds when seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds -> "#{div(seconds, 3_600)}h ago"
    end
  end
end
