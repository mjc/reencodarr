defmodule Reencodarr.Media.Video do
  use Ecto.Schema
  import Ecto.Changeset

  schema "videos" do
    field :size, :integer
    field :path, :string
    field :bitrate, :integer

    field :mediainfo, :map


    belongs_to :library, Reencodarr.Media.Library

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(video, attrs) do
    video
    |> cast(attrs, [:path, :size, :bitrate, :library_id, :mediainfo])
    |> validate_required([:path, :size])
    |> unique_constraint(:path)
  end
end
