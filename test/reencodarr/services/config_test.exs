defmodule Reencodarr.Services.ConfigTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Services.Config

  defp valid_attrs do
    %{
      url: "http://localhost:8989",
      api_key: "abc123def456",
      enabled: true,
      service_type: :sonarr
    }
  end

  describe "changeset/2" do
    test "valid attrs produce a valid changeset" do
      cs = Config.changeset(%Config{}, valid_attrs())
      assert cs.valid?
    end

    test "missing url makes changeset invalid" do
      cs = Config.changeset(%Config{}, Map.delete(valid_attrs(), :url))
      refute cs.valid?
    end

    test "missing api_key makes changeset invalid" do
      cs = Config.changeset(%Config{}, Map.delete(valid_attrs(), :api_key))
      refute cs.valid?
    end

    test "missing service_type makes changeset invalid" do
      cs = Config.changeset(%Config{}, Map.delete(valid_attrs(), :service_type))
      refute cs.valid?
    end

    test "enabled defaults to false from schema when not in attrs" do
      # enabled has default: false in schema, so it's never nil
      attrs = Map.delete(valid_attrs(), :enabled)
      cs = Config.changeset(%Config{}, attrs)
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :enabled) == false
    end

    test "invalid service_type makes changeset invalid" do
      cs = Config.changeset(%Config{}, Map.put(valid_attrs(), :service_type, :jellyfin))
      refute cs.valid?
    end

    test "service_type :sonarr is valid" do
      cs = Config.changeset(%Config{}, Map.put(valid_attrs(), :service_type, :sonarr))
      assert cs.valid?
    end

    test "service_type :radarr is valid" do
      cs = Config.changeset(%Config{}, Map.put(valid_attrs(), :service_type, :radarr))
      assert cs.valid?
    end

    test "service_type :plex is valid" do
      cs = Config.changeset(%Config{}, Map.put(valid_attrs(), :service_type, :plex))
      assert cs.valid?
    end

    test "enabled can be false" do
      cs = Config.changeset(%Config{}, Map.put(valid_attrs(), :enabled, false))
      assert cs.valid?
    end

    test "url is stored in changes" do
      cs = Config.changeset(%Config{}, valid_attrs())
      assert Ecto.Changeset.get_change(cs, :url) == "http://localhost:8989"
    end
  end
end
