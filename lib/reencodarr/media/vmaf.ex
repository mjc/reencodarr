defmodule Reencodarr.Media.Vmaf do
  use Ecto.Schema
  import Ecto.Changeset

  @type t() :: %__MODULE__{}

  schema "vmafs" do
    field :crf, :float
    field :score, :float
    field :percent, :float
    field :chosen, :boolean, default: false
    field :size, :string
    field :time, :integer
    field :params, {:array, :string}

    belongs_to :video, Reencodarr.Media.Video

    timestamps(type: :utc_datetime)
  end

  @spec changeset(%{optional(:__struct__) => none(), optional(atom() | binary()) => any()}) ::
          Ecto.Changeset.t()
  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(vmaf \\ %__MODULE__{}, attrs) do
    vmaf
    |> cast(attrs, [:score, :crf, :percent, :chosen, :size, :time, :params, :video_id])
    |> maybe_mark_chosen()
    |> validate_required([:score, :crf, :params])
    |> foreign_key_constraint(:video_id, name: "vmafs_video_id_fkey")
  end

  defp maybe_mark_chosen(params) do
    dbg(params)
  end
end
