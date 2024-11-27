defmodule Reencodarr.Media.Library do
  use Ecto.Schema
  import Ecto.Changeset

  @type t() :: %__MODULE__{}

  schema "libraries" do
    field :monitor, :boolean, default: false
    field :path, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(library, attrs) do
    library
    |> cast(attrs, [:path, :monitor])
    |> validate_required([:path, :monitor])
    |> unique_constraint(:path)
  end
end
