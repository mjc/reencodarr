defmodule Reencodarr.Services.Config do
  use Ecto.Schema
  import Ecto.Changeset

  schema "configs" do
    field :api_key, :string, redact: true
    field :enabled, :boolean, default: false
    field :service_type, Ecto.Enum, values: [:sonarr, :radarr, :plex]
    field :url, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(config, attrs) do
    config
    |> cast(attrs, [:url, :api_key, :enabled, :service_type])
    |> validate_required([:url, :api_key, :enabled, :service_type])
  end
end
