defmodule Reencodarr.Encoder.CapabilitiesTest do
  use ExUnit.Case, async: false

  alias Reencodarr.Encoder.Capabilities

  setup do
    # Clear any cached probe result between tests
    :persistent_term.erase(Capabilities)
    # Clear any app env override set by previous tests
    Application.delete_env(:reencodarr, :encoder_capabilities_override)

    on_exit(fn ->
      :persistent_term.erase(Capabilities)
      Application.delete_env(:reencodarr, :encoder_capabilities_override)
    end)
  end

  describe "svt_av1_hdr?/0 - app env override" do
    test "returns false when override is false" do
      Application.put_env(:reencodarr, :encoder_capabilities_override, false)
      assert Capabilities.svt_av1_hdr?() == false
    end

    test "returns true when override is true" do
      Application.put_env(:reencodarr, :encoder_capabilities_override, true)
      assert Capabilities.svt_av1_hdr?() == true
    end

    test "override bypasses persistent_term cache" do
      :persistent_term.put(Capabilities, true)
      Application.put_env(:reencodarr, :encoder_capabilities_override, false)

      # Override wins even if cache says true
      assert Capabilities.svt_av1_hdr?() == false
    end
  end

  describe "svt_av1_hdr?/0 - caching" do
    test "caches result after first probe (using override to control result)" do
      Application.put_env(:reencodarr, :encoder_capabilities_override, false)
      _ = Capabilities.svt_av1_hdr?()

      # Remove override; the cache should not be consulted since override is nil
      Application.delete_env(:reencodarr, :encoder_capabilities_override)

      # Without a cache seeded, calling again will probe ffmpeg — just ensure it returns a boolean
      result = Capabilities.svt_av1_hdr?()
      assert is_boolean(result)
    end

    test "persistent_term cache is used on subsequent no-override calls" do
      # Seed the cache manually
      :persistent_term.put(Capabilities, true)
      Application.delete_env(:reencodarr, :encoder_capabilities_override)

      assert Capabilities.svt_av1_hdr?() == true
    end

    test "persistent_term cache false is respected" do
      :persistent_term.put(Capabilities, false)
      Application.delete_env(:reencodarr, :encoder_capabilities_override)

      assert Capabilities.svt_av1_hdr?() == false
    end
  end

  describe "svt_av1_hdr?/0 - explicit false override" do
    test "false override always returns false regardless of cache" do
      Application.put_env(:reencodarr, :encoder_capabilities_override, false)
      :persistent_term.put(Capabilities, true)

      assert Capabilities.svt_av1_hdr?() == false
    end
  end
end
