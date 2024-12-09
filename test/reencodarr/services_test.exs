defmodule Reencodarr.ServicesTest do
  use Reencodarr.DataCase

  alias Reencodarr.Services

  describe "configs" do
    alias Reencodarr.Services.Config

    import Reencodarr.ServicesFixtures

    @invalid_attrs %{api_key: nil, enabled: nil, service_type: nil, url: nil}

    test "list_configs/0 returns all configs" do
      config = config_fixture()
      assert Services.list_configs() == [config]
    end

    test "get_config!/1 returns the config with given id" do
      config = config_fixture()
      assert Services.get_config!(config.id) == config
    end

    test "create_config/1 with valid data creates a config" do
      valid_attrs = %{api_key: "some api_key", enabled: true, service_type: :sonarr, url: "some url"}

      assert {:ok, %Config{} = config} = Services.create_config(valid_attrs)
      assert config.api_key == "some api_key"
      assert config.enabled == true
      assert config.service_type == :sonarr
      assert config.url == "some url"
    end

    test "create_config/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Services.create_config(@invalid_attrs)
    end

    test "update_config/2 with valid data updates the config" do
      config = config_fixture()
      update_attrs = %{api_key: "some updated api_key", enabled: false, service_type: :radarr, url: "some updated url"}

      assert {:ok, %Config{} = config} = Services.update_config(config, update_attrs)
      assert config.api_key == "some updated api_key"
      assert config.enabled == false
      assert config.service_type == :radarr
      assert config.url == "some updated url"
    end

    test "update_config/2 with invalid data returns error changeset" do
      config = config_fixture()
      assert {:error, %Ecto.Changeset{}} = Services.update_config(config, @invalid_attrs)
      assert config == Services.get_config!(config.id)
    end

    test "delete_config/1 deletes the config" do
      config = config_fixture()
      assert {:ok, %Config{}} = Services.delete_config(config)
      assert_raise Ecto.NoResultsError, fn -> Services.get_config!(config.id) end
    end

    test "change_config/1 returns a config changeset" do
      config = config_fixture()
      assert %Ecto.Changeset{} = Services.change_config(config)
    end
  end
end
