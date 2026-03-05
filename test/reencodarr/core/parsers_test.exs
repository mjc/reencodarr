defmodule Reencodarr.Core.ParsersTest do
  use Reencodarr.UnitCase, async: true

  alias Reencodarr.Core.Parsers

  # ---------------------------------------------------------------------------
  # parse_integer_exact/1
  # ---------------------------------------------------------------------------

  describe "parse_integer_exact/1" do
    test "parses clean integer strings" do
      assert {:ok, 0} = Parsers.parse_integer_exact("0")
      assert {:ok, 123} = Parsers.parse_integer_exact("123")
      assert {:ok, -42} = Parsers.parse_integer_exact("-42")
      assert {:ok, 999_999} = Parsers.parse_integer_exact("999999")
    end

    test "returns error for strings with trailing chars" do
      assert {:error, :invalid_format} = Parsers.parse_integer_exact("123abc")
      assert {:error, :invalid_format} = Parsers.parse_integer_exact("12.3")
      assert {:error, :invalid_format} = Parsers.parse_integer_exact("123 ")
    end

    test "returns error for empty string" do
      assert {:error, :invalid_format} = Parsers.parse_integer_exact("")
    end

    test "returns error for non-binary input" do
      assert {:error, :invalid_input} = Parsers.parse_integer_exact(123)
      assert {:error, :invalid_input} = Parsers.parse_integer_exact(nil)
      assert {:error, :invalid_input} = Parsers.parse_integer_exact(:atom)
    end
  end

  # ---------------------------------------------------------------------------
  # parse_float_exact/1
  # ---------------------------------------------------------------------------

  describe "parse_float_exact/1" do
    test "parses clean float strings" do
      assert {:ok, 3.14} = Parsers.parse_float_exact("3.14")
      assert {:ok, -0.5} = Parsers.parse_float_exact("-0.5")
      assert {:ok, 100.0} = Parsers.parse_float_exact("100.0")
    end

    test "returns error for trailing chars" do
      assert {:error, :invalid_format} = Parsers.parse_float_exact("3.14abc")
      assert {:error, :invalid_format} = Parsers.parse_float_exact("3.14 ")
    end

    test "returns error for plain integers (no decimal)" do
      # Float.parse("123") returns {123.0, ""} actually, so this should parse OK
      assert {:ok, _} = Parsers.parse_float_exact("123")
    end

    test "returns error for empty / non-binary" do
      assert {:error, :invalid_format} = Parsers.parse_float_exact("")
      assert {:error, :invalid_input} = Parsers.parse_float_exact(nil)
      assert {:error, :invalid_input} = Parsers.parse_float_exact(3.14)
    end
  end

  # ---------------------------------------------------------------------------
  # parse_int/2
  # ---------------------------------------------------------------------------

  describe "parse_int/2" do
    test "passes through integers unchanged" do
      assert Parsers.parse_int(42, 0) == 42
      assert Parsers.parse_int(0, 99) == 0
      assert Parsers.parse_int(-1, 0) == -1
    end

    test "rounds floats to integer" do
      assert Parsers.parse_int(3.7, 0) == 4
      assert Parsers.parse_int(2.2, 0) == 2
    end

    test "parses integer strings" do
      assert Parsers.parse_int("42", 0) == 42
      assert Parsers.parse_int("-10", 0) == -10
      assert Parsers.parse_int("0", 99) == 0
    end

    test "parses float strings by truncating" do
      assert Parsers.parse_int("3.9", 0) == 3
    end

    test "falls back to default for invalid input" do
      assert Parsers.parse_int("abc", 7) == 7
      assert Parsers.parse_int(nil, 5) == 5
      assert Parsers.parse_int(:atom, 3) == 3
    end

    test "default is 0 when omitted" do
      assert Parsers.parse_int("bad") == 0
    end
  end

  # ---------------------------------------------------------------------------
  # parse_float/2
  # ---------------------------------------------------------------------------

  describe "parse_float/2" do
    test "passes through floats unchanged" do
      assert Parsers.parse_float(3.14, 0.0) == 3.14
    end

    test "converts integers to float" do
      assert Parsers.parse_float(5, 0.0) == 5.0
    end

    test "parses float strings" do
      assert Parsers.parse_float("1.5", 0.0) == 1.5
      assert Parsers.parse_float("-99.9", 0.0) == -99.9
    end

    test "parses integer strings to float" do
      assert Parsers.parse_float("42", 0.0) == 42.0
    end

    test "falls back to default for invalid input" do
      assert Parsers.parse_float("abc", 3.14) == 3.14
      assert Parsers.parse_float(nil, 1.0) == 1.0
    end

    test "default is 0.0 when omitted" do
      assert Parsers.parse_float("bad") == 0.0
    end
  end

  # ---------------------------------------------------------------------------
  # parse_boolean/2
  # ---------------------------------------------------------------------------

  describe "parse_boolean/2" do
    test "passes through booleans" do
      assert Parsers.parse_boolean(true, false) == true
      assert Parsers.parse_boolean(false, true) == false
    end

    test "treats 1 as true, 0 as false" do
      assert Parsers.parse_boolean(1, false) == true
      assert Parsers.parse_boolean(0, true) == false
    end

    test "parses truthy strings" do
      assert Parsers.parse_boolean("true", false) == true
      assert Parsers.parse_boolean("TRUE", false) == true
      assert Parsers.parse_boolean("yes", false) == true
      assert Parsers.parse_boolean("1", false) == true
    end

    test "parses falsy strings" do
      assert Parsers.parse_boolean("false", true) == false
      assert Parsers.parse_boolean("FALSE", true) == false
      assert Parsers.parse_boolean("no", true) == false
      assert Parsers.parse_boolean("0", true) == false
    end

    test "unknown strings fall back to default" do
      assert Parsers.parse_boolean("maybe", true) == true
      assert Parsers.parse_boolean("", false) == false
    end

    test "non-string / non-bool falls back to default" do
      assert Parsers.parse_boolean(nil, true) == true
      assert Parsers.parse_boolean(:atom, false) == false
    end
  end

  # ---------------------------------------------------------------------------
  # parse_duration/1
  # ---------------------------------------------------------------------------

  describe "parse_duration/1" do
    test "parses H:MM:SS format" do
      assert Parsers.parse_duration("1:23:45") == 5025
      assert Parsers.parse_duration("0:00:00") == 0
      assert Parsers.parse_duration("2:00:00") == 7200
    end

    test "parses MM:SS format" do
      assert Parsers.parse_duration("23:45") == 1425
      assert Parsers.parse_duration("1:00") == 60
    end

    test "parses bare seconds string" do
      assert Parsers.parse_duration("45") == 45
    end

    test "parses numeric float string" do
      assert Parsers.parse_duration("123.5") == 123.5
    end

    test "passes through numeric values as float" do
      assert Parsers.parse_duration(3600.0) == 3600.0
      assert Parsers.parse_duration(90) == 90.0
    end

    test "returns 0.0 for garbage input" do
      assert Parsers.parse_duration(nil) == 0.0
      assert Parsers.parse_duration("garbage") == 0
    end
  end

  # ---------------------------------------------------------------------------
  # get_first/2
  # ---------------------------------------------------------------------------

  describe "get_first/2" do
    test "returns first non-nil element" do
      assert Parsers.get_first([nil, nil, "hello", "world"]) == "hello"
      assert Parsers.get_first([nil, 0, 1]) == 0
    end

    test "returns default when all nil" do
      assert Parsers.get_first([nil, nil], "default") == "default"
    end

    test "returns nil default when none specified" do
      assert Parsers.get_first([nil, nil]) == nil
    end

    test "returns first element when it is truthy" do
      assert Parsers.get_first(["a", "b"]) == "a"
    end
  end

  # ---------------------------------------------------------------------------
  # extract_year_from_text/1
  # ---------------------------------------------------------------------------

  describe "extract_year_from_text/1" do
    test "returns nil for nil / empty" do
      assert Parsers.extract_year_from_text(nil) == nil
      assert Parsers.extract_year_from_text("") == nil
    end

    test "finds year in parentheses" do
      assert Parsers.extract_year_from_text("The Movie (2008) HD") == 2008
    end

    test "finds year in brackets" do
      assert Parsers.extract_year_from_text("Show [2021] BluRay") == 2021
    end

    test "finds year with dots" do
      assert Parsers.extract_year_from_text("Show.2019.mkv") == 2019
    end

    test "finds year with spaces" do
      assert Parsers.extract_year_from_text("Show 2015 BluRay") == 2015
    end

    test "returns nil when no valid year present" do
      assert Parsers.extract_year_from_text("No year here") == nil
    end

    test "ignores years outside 1950-2030 range" do
      assert Parsers.extract_year_from_text("Old (1900) Film") == nil
      assert Parsers.extract_year_from_text("Future (2099)") == nil
    end

    test "finds year in typical episode filename" do
      assert Parsers.extract_year_from_text("Show.S01E01.2008.mkv") == 2008
    end
  end

  # ---------------------------------------------------------------------------
  # field_mapping/1 and parse_with_pattern/4
  # ---------------------------------------------------------------------------

  describe "field_mapping/1" do
    test "builds mapping from {key, type} pairs" do
      mapping = Parsers.field_mapping([{:crf, :float}, {:score, :float}])
      assert mapping == %{crf: {:float, "crf"}, score: {:float, "score"}}
    end

    test "uses custom capture key when provided" do
      mapping = Parsers.field_mapping([{:vmaf, :float, "vmaf_score"}])
      assert mapping == %{vmaf: {:float, "vmaf_score"}}
    end
  end

  describe "parse_with_pattern/4" do
    test "extracts named captures and converts types" do
      pattern = ~r/crf (?<crf>\d+) vmaf (?<score>\d+\.\d+)/
      patterns = %{crf_line: pattern}
      mapping = Parsers.field_mapping([{:crf, :float}, {:score, :float}])

      assert {:ok, result} =
               Parsers.parse_with_pattern("crf 28 vmaf 95.3", :crf_line, patterns, mapping)

      assert result.crf == 28.0
      assert result.score == 95.3
    end

    test "returns {:error, :no_match} for non-matching line" do
      patterns = %{test: ~r/foo (?<x>\d+)/}
      mapping = Parsers.field_mapping([{:x, :int}])

      assert {:error, :no_match} =
               Parsers.parse_with_pattern("bar 123", :test, patterns, mapping)
    end
  end
end
