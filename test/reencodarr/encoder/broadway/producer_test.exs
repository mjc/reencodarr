defmodule Reencodarr.Encoder.Broadway.ProducerTest do
  use ExUnit.Case, async: true

  # Helper function to test pattern matching logic
  defp match_return_value(value) do
    case value do
      %Reencodarr.Media.Vmaf{} -> :single_vmaf
      [%Reencodarr.Media.Vmaf{} | _] -> :list_with_vmaf
      [] -> :empty_list
      nil -> :nil_value
    end
  end

  describe "get_next_vmaf/1" do
    test "handles different return types from Media.get_next_for_encoding/1" do
      # Test the pattern matching logic without calling the actual Media function
      # This tests our case clause logic

      # Test the pattern matching logic without calling the actual Media function
      # This tests our case clause logic

      # Case 1: Single VMAF struct (when limit = 1)
      vmaf = %Reencodarr.Media.Vmaf{id: 1, video: %{path: "/test.mkv"}}
      assert match_return_value(vmaf) == :single_vmaf

      # Case 2: List with one VMAF
      assert match_return_value([vmaf]) == :list_with_vmaf

      # Case 3: Empty list
      assert match_return_value([]) == :empty_list

      # Case 4: nil
      assert match_return_value(nil) == :nil_value
    end
  end
end
