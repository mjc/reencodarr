defmodule Reencodarr.Media.Vmaf do
  use Ecto.Schema
  import Ecto.Changeset

  @type t() :: %__MODULE__{}

  schema "vmafs" do
    field :crf, :float
    field :score, :float
    field :chosen, :boolean, default: false
    field :params, {:array, :string}

    field :video_id, :id

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(vmaf \\ %__MODULE__{}, attrs) do
    vmaf
    |> cast(attrs, [:score, :crf, :chosen, :params])
    |> validate_required([:score, :crf, :params])
  end
end
