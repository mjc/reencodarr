defmodule Reencodarr.Media.ResolutionParserTest do
  use ExUnit.Case, async: true
  alias Reencodarr.DataConverters

  describe "parse/1" do
    test "parses string resolution" do
      assert DataConverters.parse_resolution("1920x1080") == {:ok, {1920, 1080}}
      assert DataConverters.parse_resolution("720x480") == {:ok, {720, 480}}
    end

    test "handles tuple resolution" do
      assert DataConverters.parse_resolution({1920, 1080}) == {:ok, {1920, 1080}}
    end

    test "handles nil input" do
      assert DataConverters.parse_resolution(nil) == {:error, "Resolution cannot be nil"}
    end

    test "handles invalid format" do
      assert DataConverters.parse_resolution("invalid") ==
               {:error, "Invalid resolution format: invalid"}

      assert DataConverters.parse_resolution("1920") ==
               {:error, "Invalid resolution format: 1920"}

      assert DataConverters.parse_resolution("1920x") ==
               {:error, "Invalid resolution format: 1920x"}
    end
  end

  describe "parse_with_fallback/2" do
    test "returns parsed resolution on success" do
      assert DataConverters.parse_resolution_with_fallback("1920x1080") == {1920, 1080}
    end

    test "returns fallback on failure" do
      assert DataConverters.parse_resolution_with_fallback("invalid") == {0, 0}
      assert DataConverters.parse_resolution_with_fallback("invalid", {720, 480}) == {720, 480}
    end
  end

  describe "format/1" do
    test "formats resolution tuple to string" do
      assert DataConverters.format_resolution({1920, 1080}) == "1920x1080"
    end
  end

  describe "valid_resolution?/1" do
    test "validates reasonable resolutions" do
      assert DataConverters.valid_resolution?({1920, 1080}) == true
      assert DataConverters.valid_resolution?({720, 480}) == true
    end

    test "rejects invalid resolutions" do
      assert DataConverters.valid_resolution?({0, 0}) == false
      assert DataConverters.valid_resolution?({-1, 1080}) == false
      assert DataConverters.valid_resolution?({8000, 5000}) == false
    end
  end
end
