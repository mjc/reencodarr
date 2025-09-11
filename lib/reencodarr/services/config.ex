defmodule Reencodarr.Services.Config do
  @moduledoc "Represents configuration settings for external services."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          api_key: String.t() | nil,
          enabled: boolean(),
          service_type: :sonarr | :radarr | :plex,
          url: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

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
    |> unique_constraint(:service_type)
  end
end
