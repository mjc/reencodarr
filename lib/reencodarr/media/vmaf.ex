defmodule Reencodarr.Media.Vmaf do
  use Ecto.Schema
  import Ecto.Changeset

  schema "vmafs" do
    field :crf, :float
    field :score, :float
    field :video_id, :id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(vmaf, attrs) do
    vmaf
    |> cast(attrs, [:score, :crf])
    |> validate_required([:score, :crf])
  end
end
