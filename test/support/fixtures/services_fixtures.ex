defmodule Reencodarr.ServicesFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Reencodarr.Services` context.
  """

  @doc """
  Generate a config.
  """
  def config_fixture(attrs \\ %{}) do
    {:ok, config} =
      attrs
      |> Enum.into(%{
        api_key: "some api_key",
        enabled: true,
        service_type: :sonarr,
        url: "some url"
      })
      |> Reencodarr.Services.create_config()

    config
  end
end
