defmodule Reencodarr.DataConvertersTest do
  use ExUnit.Case, async: true

  alias Reencodarr.DataConverters

  describe "parse_resolution/1" do
    test "parses '1920x1080' to {:ok, {1920, 1080}}" do
      assert {:ok, {1920, 1080}} = DataConverters.parse_resolution("1920x1080")
    end

    test "parses '720x480' to {:ok, {720, 480}}" do
      assert {:ok, {720, 480}} = DataConverters.parse_resolution("720x480")
    end

    test "parses '3840x2160' (4K) to {:ok, {3840, 2160}}" do
      assert {:ok, {3840, 2160}} = DataConverters.parse_resolution("3840x2160")
    end

    test "parses tuple {1920, 1080} directly" do
      assert {:ok, {1920, 1080}} = DataConverters.parse_resolution({1920, 1080})
    end

    test "returns error for nil" do
      assert {:error, "Resolution cannot be nil"} = DataConverters.parse_resolution(nil)
    end

    test "returns error for invalid format" do
      assert {:error, _} = DataConverters.parse_resolution("not-a-resolution")
    end

    test "returns error for non-numeric components" do
      assert {:error, _} = DataConverters.parse_resolution("abcxdef")
    end

    test "returns error for single component without x" do
      assert {:error, _} = DataConverters.parse_resolution("1920")
    end

    test "returns error for float-only input" do
      assert {:error, _} = DataConverters.parse_resolution(3.14)
    end

    test "returns error for list input" do
      assert {:error, _} = DataConverters.parse_resolution([1920, 1080])
    end
  end

  describe "parse_resolution_with_fallback/2" do
    test "returns resolution for valid string" do
      assert {1920, 1080} = DataConverters.parse_resolution_with_fallback("1920x1080")
    end

    test "returns default fallback {0, 0} for invalid string" do
      assert {0, 0} = DataConverters.parse_resolution_with_fallback("bad")
    end

    test "returns custom fallback for invalid string" do
      assert {640, 480} = DataConverters.parse_resolution_with_fallback("bad", {640, 480})
    end

    test "returns resolution for valid tuple" do
      assert {1280, 720} = DataConverters.parse_resolution_with_fallback({1280, 720})
    end

    test "returns fallback for nil" do
      assert {0, 0} = DataConverters.parse_resolution_with_fallback(nil)
    end
  end

  describe "format_resolution/1" do
    test "formats {1920, 1080} to '1920x1080'" do
      assert "1920x1080" = DataConverters.format_resolution({1920, 1080})
    end

    test "formats {3840, 2160} to '3840x2160'" do
      assert "3840x2160" = DataConverters.format_resolution({3840, 2160})
    end

    test "formats {720, 480} to '720x480'" do
      assert "720x480" = DataConverters.format_resolution({720, 480})
    end
  end

  describe "valid_resolution?/1" do
    test "returns true for common 1080p resolution" do
      assert DataConverters.valid_resolution?({1920, 1080})
    end

    test "returns true for 4K UHD resolution" do
      assert DataConverters.valid_resolution?({3840, 2160})
    end

    test "returns true for 720p resolution" do
      assert DataConverters.valid_resolution?({1280, 720})
    end

    test "returns true for minimum valid 1x1 resolution" do
      assert DataConverters.valid_resolution?({1, 1})
    end

    test "returns true for max resolution 7680x4320 (8K)" do
      assert DataConverters.valid_resolution?({7680, 4320})
    end

    test "returns false for zero width" do
      refute DataConverters.valid_resolution?({0, 1080})
    end

    test "returns false for zero height" do
      refute DataConverters.valid_resolution?({1920, 0})
    end

    test "returns false for width exceeding 7680" do
      refute DataConverters.valid_resolution?({7681, 1080})
    end

    test "returns false for height exceeding 4320" do
      refute DataConverters.valid_resolution?({1920, 4321})
    end

    test "returns false for nil" do
      refute DataConverters.valid_resolution?(nil)
    end

    test "returns false for string" do
      refute DataConverters.valid_resolution?("1920x1080")
    end

    test "returns false for negative dimensions" do
      refute DataConverters.valid_resolution?({-1920, 1080})
    end
  end

  describe "parse_duration/1" do
    test "parses numeric duration as float" do
      assert DataConverters.parse_duration(3600) == 3600.0
    end

    test "parses float duration unchanged" do
      assert DataConverters.parse_duration(5400.5) == 5400.5
    end

    test "returns 0.0 for nil" do
      assert DataConverters.parse_duration(nil) == 0.0
    end

    test "returns 0.0 for non-parseable atom" do
      assert DataConverters.parse_duration(:invalid) == 0.0
    end
  end

  describe "parse_numeric/2" do
    test "parses integer string to float" do
      assert DataConverters.parse_numeric("42") == 42.0
    end

    test "parses float string to float" do
      assert DataConverters.parse_numeric("3.14") == 3.14
    end

    test "passes through integer as float" do
      assert DataConverters.parse_numeric(10) == 10.0
    end

    test "passes through float unchanged" do
      assert DataConverters.parse_numeric(3.14) == 3.14
    end

    test "returns 0.0 for nil" do
      assert DataConverters.parse_numeric(nil) == 0.0
    end

    test "returns 0.0 for non-parseable string" do
      assert DataConverters.parse_numeric("not-a-number") == 0.0
    end

    test "strips units before parsing" do
      assert DataConverters.parse_numeric("5000000 b/s", units: [" b/s"]) == 5_000_000.0
    end

    test "strips multiple units" do
      assert DataConverters.parse_numeric("256 MiB/s", units: [" MiB/s"]) == 256.0
    end

    test "returns 0.0 for string with surrounding whitespace (no trim performed)" do
      # parse_numeric does not trim whitespace, so "  42  " fails to parse
      assert DataConverters.parse_numeric("  42  ") == 0.0
    end
  end
end
