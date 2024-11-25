defmodule Reencodarr.Media.Video do
  use Ecto.Schema
  import Ecto.Changeset

  schema "videos" do
    field :size, :integer
    field :path, :string
    field :bitrate, :integer

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(video, attrs) do
    video
    |> cast(attrs, [:path, :size, :bitrate])
    |> validate_required([:path, :size])
  end
end
