defmodule Reencodarr.Core.ModeTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Core.Mode

  describe "mode detection" do
    test "defaults to monolithic mode" do
      # Ensure no mode is set to test the default
      original_mode = Application.get_env(:reencodarr, :mode)
      Application.delete_env(:reencodarr, :mode)
      
      try do
        # Default configuration should be monolithic
        assert Mode.current_mode() == :monolithic
        assert Mode.monolithic?()
        refute Mode.server?()
        refute Mode.client?()
        refute Mode.distributed?()
      after
        if original_mode do
          Application.put_env(:reencodarr, :mode, original_mode)
        end
      end
    end

    test "server mode configuration" do
      # Temporarily set server mode
      original_mode = Application.get_env(:reencodarr, :mode)
      Application.put_env(:reencodarr, :mode, :server)
      
      try do
        assert Mode.current_mode() == :server
        refute Mode.monolithic?()
        assert Mode.server?()
        refute Mode.client?()
        assert Mode.distributed?()
        assert Mode.server_node() == nil
      after
        Application.put_env(:reencodarr, :mode, original_mode)
      end
    end

    test "client mode configuration" do
      # Temporarily set client mode with server node
      original_mode = Application.get_env(:reencodarr, :mode)
      original_server_node = Application.get_env(:reencodarr, :server_node)
      
      Application.put_env(:reencodarr, :mode, :client)
      Application.put_env(:reencodarr, :server_node, :"server@localhost")
      
      try do
        assert Mode.current_mode() == :client
        refute Mode.monolithic?()
        refute Mode.server?()
        assert Mode.client?()
        assert Mode.distributed?()
        assert Mode.server_node() == :"server@localhost"
      after
        Application.put_env(:reencodarr, :mode, original_mode)
        Application.put_env(:reencodarr, :server_node, original_server_node)
      end
    end
  end

  describe "capabilities" do
    test "monolithic mode has all capabilities" do
      original_mode = Application.get_env(:reencodarr, :mode)
      Application.put_env(:reencodarr, :mode, :monolithic)
      
      try do
        capabilities = Mode.node_capabilities()
        assert :analysis in capabilities
        assert :crf_search in capabilities
        assert :encoding in capabilities
        assert :file_transfer in capabilities
      after
        Application.put_env(:reencodarr, :mode, original_mode)
      end
    end

    test "server mode has analysis and file transfer capabilities" do
      original_mode = Application.get_env(:reencodarr, :mode)
      Application.put_env(:reencodarr, :mode, :server)
      
      try do
        capabilities = Mode.node_capabilities()
        assert :analysis in capabilities
        assert :file_transfer in capabilities
        refute :crf_search in capabilities
        refute :encoding in capabilities
      after
        Application.put_env(:reencodarr, :mode, original_mode)
      end
    end

    test "client mode has configurable capabilities" do
      original_mode = Application.get_env(:reencodarr, :mode)
      original_capabilities = Application.get_env(:reencodarr, :client_capabilities)
      
      Application.put_env(:reencodarr, :mode, :client)
      Application.put_env(:reencodarr, :client_capabilities, [:crf_search, :encoding])
      
      try do
        capabilities = Mode.node_capabilities()
        assert :crf_search in capabilities
        assert :encoding in capabilities
        refute :analysis in capabilities
        refute :file_transfer in capabilities
      after
        Application.put_env(:reencodarr, :mode, original_mode)
        Application.put_env(:reencodarr, :client_capabilities, original_capabilities)
      end
    end
  end

  describe "validation" do
    test "monolithic mode is always valid" do
      original_mode = Application.get_env(:reencodarr, :mode)
      Application.put_env(:reencodarr, :mode, :monolithic)
      
      try do
        assert Mode.validate_config() == :ok
      after
        Application.put_env(:reencodarr, :mode, original_mode)
      end
    end

    test "client mode requires server node configuration" do
      original_mode = Application.get_env(:reencodarr, :mode)
      original_server_node = Application.get_env(:reencodarr, :server_node)
      
      Application.put_env(:reencodarr, :mode, :client)
      Application.delete_env(:reencodarr, :server_node)
      
      try do
        assert {:error, "Client mode requires :server_node configuration"} = Mode.validate_config()
      after
        Application.put_env(:reencodarr, :mode, original_mode)
        Application.put_env(:reencodarr, :server_node, original_server_node)
      end
    end
  end
end
