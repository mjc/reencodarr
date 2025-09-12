defmodule Reencodarr.ConfigTest do
  use Reencodarr.UnitCase, async: true

  alias Reencodarr.Config

  describe "exclude_patterns/0" do
    test "returns empty list by default" do
      # Config should be empty by default
      patterns = Config.exclude_patterns()
      assert is_list(patterns)
      # Should be empty or have only commented-out patterns
      assert patterns == []
    end
  end

  describe "temp_dir/0" do
    test "returns configured temp directory" do
      temp_dir = Config.temp_dir()
      assert is_binary(temp_dir)
      assert String.contains?(temp_dir, "ab-av1")
    end
  end
end
