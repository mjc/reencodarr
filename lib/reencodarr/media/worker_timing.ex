defmodule Reencodarr.Media.WorkerTiming do
  @moduledoc "Pause-excluded worker counters, checkpointed per attempt to deduplicate replay."
  use Ecto.Schema
  import Ecto.Query

  alias Reencodarr.AbAv1.WorkerProtocol.JobTiming
  alias Reencodarr.{DbWriter, Repo}
  alias Reencodarr.Media.Video

  @primary_key {:job_id, :string, autogenerate: false}
  @type t :: %__MODULE__{}
  schema "worker_job_timings" do
    belongs_to :video, Video
    field :job_type, Ecto.Enum, values: [:crf_search, :encode]
    field :worker_id, :string
    field :active_milliseconds, :integer, default: 0
    field :finalization_milliseconds, :integer, default: 0
    field :finalized, :boolean, default: false
  end

  @spec active_milliseconds(pos_integer(), String.t() | nil) :: non_neg_integer()
  def active_milliseconds(_video_id, nil), do: 0

  def active_milliseconds(video_id, job_id) do
    Repo.one(
      from(t in __MODULE__,
        where: t.video_id == ^video_id and t.job_id == ^job_id,
        select: t.active_milliseconds
      )
    ) || 0
  end

  @spec record(String.t(), JobTiming.t()) ::
          {:ok, :applied | :duplicate} | {:error, :stale_worker_attempt}
  def record(worker_id, %JobTiming{active_milliseconds: milliseconds} = report)
      when is_binary(worker_id) and is_integer(milliseconds) and milliseconds >= 0 and
             milliseconds <= 9_223_372_036_854_775_807 do
    DbWriter.transaction(
      fn ->
        video = Repo.get(Video, report.video_id)
        checkpoint = Repo.get(__MODULE__, report.job_id)

        valid? =
          authorized?(video, checkpoint, worker_id, report) and valid_counter?(checkpoint, report)

        if not valid?, do: Repo.rollback(:stale_worker_attempt)

        new? = is_nil(checkpoint)

        checkpoint =
          checkpoint ||
            Repo.insert!(%__MODULE__{
              job_id: report.job_id,
              video_id: report.video_id,
              job_type: report.job_type,
              worker_id: worker_id
            })

        delta = milliseconds - checkpoint.active_milliseconds

        if delta > 0 or new? do
          Repo.update_all(from(t in __MODULE__, where: t.job_id == ^report.job_id),
            set: [active_milliseconds: milliseconds]
          )

          add_seconds(report.video_id, report.job_type, delta)
          :applied
        else
          :duplicate
        end
      end,
      label: :worker_timing_record
    )
  end

  @spec finish(pos_integer(), String.t(), non_neg_integer()) ::
          {:ok, :applied | :duplicate} | {:error, term()}
  @spec finish(pos_integer(), String.t(), non_neg_integer(), boolean()) ::
          {:ok, :applied | :duplicate} | {:error, term()}
  def finish(video_id, job_id, milliseconds, finalized? \\ true)
      when is_integer(milliseconds) and milliseconds >= 0 and is_boolean(finalized?) do
    DbWriter.transaction(
      fn ->
        case Repo.get_by(__MODULE__, job_id: job_id, video_id: video_id) do
          %__MODULE__{finalized: false} = checkpoint ->
            Repo.update_all(from(t in __MODULE__, where: t.job_id == ^job_id),
              set: [
                finalization_milliseconds: checkpoint.finalization_milliseconds + milliseconds,
                finalized: finalized?
              ]
            )

            add_seconds(video_id, checkpoint.job_type, milliseconds)
            :applied

          _ ->
            :duplicate
        end
      end,
      label: :worker_timing_finish
    )
  end

  defp authorized?(%Video{} = video, nil, worker_id, report) do
    video.worker_attempt_id == report.job_id and
      video.state == video_state(report.job_type) and
      Map.get(video, worker_field(report.job_type)) == worker_id
  end

  defp authorized?(%Video{} = video, %__MODULE__{} = checkpoint, worker_id, report)
       when checkpoint.worker_id == worker_id and checkpoint.video_id == report.video_id and
              checkpoint.job_type == report.job_type do
    video.worker_attempt_id == report.job_id or
      (is_nil(video.worker_attempt_id) and checkpoint.finalized)
  end

  defp authorized?(_video, _checkpoint, _worker_id, _report), do: false

  defp valid_counter?(nil, _report), do: true
  defp valid_counter?(%__MODULE__{finalized: false}, _report), do: true

  defp valid_counter?(checkpoint, report),
    do: report.active_milliseconds <= checkpoint.active_milliseconds

  defp add_seconds(video_id, job_type, milliseconds) do
    column = seconds_field(job_type)

    Repo.query!(
      "UPDATE videos SET #{column} = COALESCE(#{column}, 0) + ? WHERE id = ?",
      [milliseconds / 1000, video_id]
    )
  end

  defp seconds_field(:crf_search), do: :crf_search_seconds
  defp seconds_field(:encode), do: :encode_seconds
  defp video_state(:crf_search), do: :crf_searching
  defp video_state(:encode), do: :encoding
  defp worker_field(:crf_search), do: :crf_search_worker_id
  defp worker_field(:encode), do: :encode_worker_id
end
