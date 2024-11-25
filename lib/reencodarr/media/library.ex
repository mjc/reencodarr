defmodule Reencodarr.Media.Library do
  use Ecto.Schema
  import Ecto.Changeset

  schema "libraries" do
    field :monitor, :boolean, default: false
    field :path, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(library, attrs) do
    library
    |> cast(attrs, [:path, :monitor])
    |> validate_required([:path, :monitor])
    |> unique_constraint(:path)
  end
end
