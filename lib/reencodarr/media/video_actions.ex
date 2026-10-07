defmodule Reencodarr.Media.VideoActions do
  @moduledoc "Operator actions that protect videos currently being processed."
  alias Reencodarr.AbAv1.WorkerSessions
  alias Reencodarr.{DbWriter, Media, Repo}
  alias Reencodarr.Media.Video

  def mutate(id, action) when action in [:reset, :reanalyze, :delete] do
    DbWriter.transaction(fn ->
      case Repo.get(Video, id) do
        nil ->
          Repo.rollback(:not_found)

        %{state: state} when state in [:analyzing, :crf_searching, :encoding] ->
          Repo.rollback(:active)

        video ->
          apply_action(video, action) |> unwrap_action()
      end
    end)
  end

  def control(id, action) when action in [:pause, :resume, :stop] do
    match =
      for session <- WorkerSessions.list(),
          {_, job} <- session.jobs,
          job.video_id == id and job.active,
          do: {session.server_worker_id, job.job_id}

    case match do
      [{worker_id, job_id} | _] -> WorkerSessions.request_control(worker_id, job_id, action)
      [] -> {:error, :worker_unavailable}
    end
  end

  defp unwrap_action({:ok, result}), do: result
  defp unwrap_action({:error, reason}), do: Repo.rollback(reason)

  defp apply_action(video, :reset), do: Media.mark_as_needs_analysis(video)
  defp apply_action(video, :reanalyze), do: Media.force_reanalyze_video(video.id)
  defp apply_action(video, :delete), do: Media.delete_video(video)
end
