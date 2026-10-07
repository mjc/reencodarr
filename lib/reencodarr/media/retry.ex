defmodule Reencodarr.Media.Retry do
  @moduledoc "Retry failed videos from the last usable workflow stage."
  import Ecto.Query
  alias Reencodarr.{DbWriter, Repo}
  alias Reencodarr.Media.{Video, VideoFailure, VideoStateMachine}

  def video(id, mode \\ :resume) when mode in [:resume, :analyze] do
    result =
      DbWriter.transaction(fn -> load_retry(id, mode) end, label: :retry_failed_video)

    case result do
      {:ok, video} -> VideoStateMachine.broadcast_state_transition(video, video.state)
      _ -> :ok
    end

    result
  end

  defp load_retry(id, mode) do
    case Repo.get(Video, id) do
      %Video{state: :failed} = video -> retry(video, mode)
      nil -> Repo.rollback(:not_found)
      _ -> Repo.rollback(:not_failed)
    end
  end

  defp retry(video, mode) do
    stage =
      Repo.one(
        from f in VideoFailure,
          where: f.video_id == ^video.id and not f.resolved,
          order_by: [desc: f.inserted_at, desc: f.id],
          limit: 1,
          select: f.failure_stage
      )

    target = target(video, stage, mode)
    attrs = if target == :needs_analysis, do: %{bitrate: nil}, else: %{}
    attrs = Map.merge(attrs, %{worker_attempt_id: nil, worker_terminal_claimed_at: nil})
    {:ok, changeset} = VideoStateMachine.transition(video, target, attrs)

    changeset =
      if changeset.valid?,
        do: changeset,
        else:
          elem(
            VideoStateMachine.transition(video, :needs_analysis, Map.put(attrs, :bitrate, nil)),
            1
          )

    updated = Repo.update!(changeset)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(f in VideoFailure, where: f.video_id == ^video.id and not f.resolved)
    |> Repo.update_all(set: [resolved: true, resolved_at: now])

    updated
  end

  defp target(_video, _stage, :analyze), do: :needs_analysis

  defp target(%{chosen_vmaf_id: id}, stage, :resume)
       when not is_nil(id) and stage in [:encoding, :post_process], do: :crf_searched

  defp target(_video, :crf_search, :resume), do: :analyzed
  defp target(_video, _stage, :resume), do: :needs_analysis
end
