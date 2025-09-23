defmodule Reencodarr.FormattersPropertyTest do
  @moduledoc """
  Property-based tests for the Formatters module.

  These tests verify that formatter functions behave correctly across
  a wide range of generated inputs, helping catch edge cases that
  traditional example-based tests might miss.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Reencodarr.Formatters
  import StreamData

  @moduletag :property

  describe "file_size/1 property tests" do
    property "always returns a string with valid binary suffixes for valid input" do
      check all(size <- integer(0..10_000_000_000)) do
        result = Formatters.file_size(size)
        assert is_binary(result)
        assert result =~ ~r/^\d+(\.\d+)? (B|KiB|MiB|GiB|TiB|PiB)$/
      end
    end

    property "returns N/A for invalid input" do
      check all(input <- invalid_input()) do
        assert Formatters.file_size(input) == "N/A"
      end
    end

    property "powers of 1024 return expected units" do
      # 0-4 to avoid huge numbers
      check all(exp <- integer(0..4)) do
        size = trunc(:math.pow(1024, exp))
        result = Formatters.file_size(size)
        units = ["B", "KiB", "MiB", "GiB", "TiB"]
        expected_unit = Enum.at(units, exp)
        assert String.contains?(result, expected_unit)
      end
    end
  end

  describe "file_size_gib/1 property tests" do
    property "always returns a non-negative float for valid input" do
      # Must be > 0 for this function
      check all(size <- integer(1..10_000_000_000)) do
        result = Formatters.file_size_gib(size)
        assert is_float(result)
        assert result >= 0.0
      end
    end

    property "returns 0.0 for invalid input" do
      check all(input <- invalid_input()) do
        assert Formatters.file_size_gib(input) == 0.0
      end
    end

    property "conversion is mathematically correct" do
      check all(gib_count <- integer(1..10)) do
        size = gib_count * 1_073_741_824
        result = Formatters.file_size_gib(size)
        expected = Float.round(gib_count * 1.0, 2)
        assert result == expected
      end
    end
  end

  describe "duration/1 property tests" do
    property "returns formatted duration string for positive values" do
      # Must be > 0 for valid duration
      check all(seconds <- integer(1..86_400)) do
        result = Formatters.duration(seconds)
        assert is_binary(result)
        assert result != ""
        assert result != "N/A"
      end
    end

    property "returns N/A for invalid input" do
      check all(input <- invalid_input()) do
        assert Formatters.duration(input) == "N/A"
      end
    end

    property "returns N/A for zero or negative values" do
      check all(seconds <- integer(-1000..0)) do
        assert Formatters.duration(seconds) == "N/A"
      end
    end
  end

  describe "count/1 property tests" do
    property "returns string representation for all numeric input" do
      check all(count <- integer(0..1_000_000)) do
        result = Formatters.count(count)
        assert is_binary(result)
        assert result != ""
      end
    end

    property "values under 1000 return exact string representation" do
      check all(count <- integer(0..999)) do
        result = Formatters.count(count)
        assert result == to_string(count)
      end
    end

    property "values 1000+ contain K, M, or B suffix" do
      check all(count <- integer(1000..999_999)) do
        result = Formatters.count(count)
        assert result =~ ~r/[KMB]$/
      end
    end
  end

  describe "bitrate/1 property tests" do
    property "returns formatted string for integer values" do
      check all(bitrate <- integer(1..100_000_000)) do
        result = Formatters.bitrate(bitrate)
        assert is_binary(result)
        # Should contain bps, kbps, or Mbps
        assert result =~ ~r/(bps|kbps|Mbps)$/
      end
    end

    property "uses correct units based on size" do
      # Test the actual thresholds based on the implementation
      check all(bitrate <- integer(1000..10_000_000)) do
        result = Formatters.bitrate(bitrate)

        if bitrate < 1_000_000 do
          # Capital K as used in implementation
          assert result =~ ~r/Kbps$/
        else
          assert result =~ ~r/Mbps$/
        end
      end
    end

    property "returns 'Unknown' for invalid input" do
      check all(input <- invalid_input()) do
        assert Formatters.bitrate(input) == "Unknown"
      end
    end

    property "very small values return bps" do
      check all(bitrate <- integer(1..999)) do
        result = Formatters.bitrate(bitrate)
        assert result =~ ~r/bps$/
        refute result =~ ~r/kbps$/
      end
    end
  end

  describe "bitrate_mbps/1 property tests" do
    property "returns formatted string with Mbps suffix for positive values" do
      check all(bitrate <- integer(1..100_000_000)) do
        result = Formatters.bitrate_mbps(bitrate)
        assert is_binary(result)
        assert result =~ ~r/^\d+(\.\d+)? Mbps$/
      end
    end

    property "returns N/A for invalid input" do
      check all(input <- invalid_input()) do
        assert Formatters.bitrate_mbps(input) == "N/A"
      end
    end
  end

  describe "vmaf_score/1 property tests" do
    property "returns formatted score for numeric values" do
      check all(score <- float(min: 0.0, max: 100.0)) do
        result = Formatters.vmaf_score(score)
        assert is_binary(result)
        assert result =~ ~r/^\d+(\.\d+)?$/
      end
    end

    property "converts non-numeric values to string" do
      check all(
              input <-
                one_of([
                  string(:ascii, max_length: 10),
                  constant(nil)
                  # Removed %{} since it doesn't implement String.Chars
                ])
            ) do
        result = Formatters.vmaf_score(input)
        assert is_binary(result)
        assert result == to_string(input)
      end
    end
  end

  describe "crf/1 property tests" do
    property "converts string-convertible input to string" do
      check all(
              input <-
                one_of([
                  integer(),
                  float(),
                  string(:ascii, max_length: 20),
                  constant(nil)
                  # Removed %{} since it doesn't implement String.Chars
                ])
            ) do
        result = Formatters.crf(input)
        assert is_binary(result)
        assert result == to_string(input)
      end
    end
  end

  describe "fps/1 property tests" do
    property "formats numeric fps values" do
      check all(fps <- one_of([integer(1..120), float(min: 1.0, max: 120.0)])) do
        result = Formatters.fps(fps)
        assert is_binary(result)
        # For numbers, should contain "fps"
        assert result =~ ~r/fps$/
      end
    end

    property "converts non-numeric values to string" do
      check all(input <- one_of([string(:ascii, max_length: 10), constant(nil)])) do
        result = Formatters.fps(input)
        assert is_binary(result)
        assert result == to_string(input)
      end
    end
  end

  describe "savings_bytes/1 property tests" do
    property "returns formatted string for positive values" do
      check all(size <- integer(1..10_000_000_000)) do
        result = Formatters.savings_bytes(size)
        assert is_binary(result)
        assert result =~ ~r/^\d+(\.\d+)? (B|KiB|MiB|GiB|TiB|PiB)$/
      end
    end

    property "returns N/A for invalid or non-positive input" do
      check all(
              input <-
                one_of([
                  constant(nil),
                  constant(0),
                  integer(-1000..-1),
                  invalid_input()
                ])
            ) do
        assert Formatters.savings_bytes(input) == "N/A"
      end
    end
  end

  # === PROPERTY GENERATORS ===

  defp invalid_input do
    one_of([
      constant(nil),
      # Short strings
      string(:ascii, max_length: 5),
      constant([])
      # Removed %{} since many functions try to convert to string
    ])
  end
end
