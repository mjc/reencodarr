defmodule Reencodarr.Media.Vmaf do
  @moduledoc "Represents VMAF quality metrics for media files."

  use Ecto.Schema
  import Ecto.Changeset

  @type t() :: %__MODULE__{}

  schema "vmafs" do
    field :crf, :float
    field :score, :float
    field :percent, :float
    field :size, :string
    field :time, :integer
    field :params, {:array, :string}
    field :savings, :integer
    field :target, :integer

    belongs_to :video, Reencodarr.Media.Video

    timestamps(type: :utc_datetime)
  end

  @spec changeset(%{optional(:__struct__) => none(), optional(atom() | binary()) => any()}) ::
          Ecto.Changeset.t()
  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(vmaf \\ %__MODULE__{}, attrs) do
    vmaf
    |> cast(attrs, [
      :score,
      :crf,
      :percent,
      :size,
      :time,
      :params,
      :video_id,
      :savings,
      :target
    ])
    |> validate_required([:score, :crf, :params])
    |> foreign_key_constraint(:video_id, name: "vmafs_video_id_fkey")
  end
end
