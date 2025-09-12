defmodule Reencodarr.AnalyzerTest do
  use Reencodarr.DataCase

  # Test Broadway modules directly since compatibility layer is removed
  alias Reencodarr.Analyzer.Broadway

  describe "Broadway analyzer API" do
    test "Broadway running status can be checked" do
      # Should not crash even when Broadway is not running in test
      result = Broadway.running?()
      assert is_boolean(result)
    end

    test "Broadway dispatch_available doesn't crash" do
      # Should handle missing producer gracefully
      case Broadway.dispatch_available() do
        :ok -> :ok
        {:error, :producer_supervisor_not_found} -> :ok
        {:error, :producer_not_found} -> :ok
        other -> flunk("Unexpected result: #{inspect(other)}")
      end
    end
  end
end
