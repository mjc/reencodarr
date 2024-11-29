defmodule Reencodarr do
  @moduledoc """
  Reencodarr keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "vmaf" do
    field :crf, :integer
    field :video_id, :integer
    # ...existing code...
  end

  def changeset(vmaf, attrs) do
    vmaf
    |> cast(attrs, [:crf, :video_id])
    |> validate_required([:crf, :video_id])
    |> unique_constraint([:crf, :video_id])

    # ...existing code...
  end
end
