defmodule Reencodarr.Media.Queue do
  use Ecto.Schema
  import Ecto.Changeset

  @type t() :: %__MODULE__{}

  schema "queues" do
    field :finished_at, :naive_datetime
    field :job_type, Ecto.Enum, values: [:crf_search, :encode]
    field :log, :string
    field :params, {:array, :string}
    field :started_at, :naive_datetime
    belongs_to :video, Reencodarr.Media.Video
    belongs_to :vmaf, Reencodarr.Media.Vmaf

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(queue, attrs) do
    queue
    |> cast(attrs, [:job_type, :started_at, :finished_at, :params, :log, :video_id, :vmaf_id])
    |> validate_required([:job_type, :video_id])
    |> unique_constraint([:video_id, :job_type])
  end
end
