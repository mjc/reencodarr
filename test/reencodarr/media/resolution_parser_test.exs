defmodule Reencodarr.Media.ResolutionParserTest do
  use ExUnit.Case, async: true
  alias Reencodarr.Media.ResolutionParser

  describe "parse/1" do
    test "parses string resolution" do
      assert ResolutionParser.parse("1920x1080") == {:ok, {1920, 1080}}
      assert ResolutionParser.parse("720x480") == {:ok, {720, 480}}
    end

    test "handles tuple resolution" do
      assert ResolutionParser.parse({1920, 1080}) == {:ok, {1920, 1080}}
    end

    test "handles nil input" do
      assert ResolutionParser.parse(nil) == {:error, :nil_input}
    end

    test "handles invalid format" do
      assert ResolutionParser.parse("invalid") == {:error, :invalid_format}
      assert ResolutionParser.parse("1920") == {:error, :invalid_format}
      assert ResolutionParser.parse("1920x") == {:error, :invalid_format}
    end
  end

  describe "parse_with_fallback/2" do
    test "returns parsed resolution on success" do
      assert ResolutionParser.parse_with_fallback("1920x1080") == {1920, 1080}
    end

    test "returns fallback on failure" do
      assert ResolutionParser.parse_with_fallback("invalid") == {0, 0}
      assert ResolutionParser.parse_with_fallback("invalid", {720, 480}) == {720, 480}
    end
  end

  describe "format/1" do
    test "formats resolution tuple to string" do
      assert ResolutionParser.format({1920, 1080}) == "1920x1080"
    end
  end

  describe "valid_resolution?/1" do
    test "validates reasonable resolutions" do
      assert ResolutionParser.valid_resolution?({1920, 1080}) == true
      assert ResolutionParser.valid_resolution?({720, 480}) == true
    end

    test "rejects invalid resolutions" do
      assert ResolutionParser.valid_resolution?({0, 0}) == false
      assert ResolutionParser.valid_resolution?({-1, 1080}) == false
      assert ResolutionParser.valid_resolution?({8000, 5000}) == false
    end
  end
end
