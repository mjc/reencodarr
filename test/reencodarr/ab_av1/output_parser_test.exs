defmodule Reencodarr.AbAv1.OutputParserTest do
  use ExUnit.Case, async: true
  alias Reencodarr.AbAv1.OutputParser

  describe "get_patterns/0" do
    test "returns a map of compiled regex patterns" do
      patterns = OutputParser.get_patterns()
      assert is_map(patterns)
    end

    test "includes all expected pattern keys" do
      patterns = OutputParser.get_patterns()

      expected_keys = [
        :encoding_sample,
        :simple_vmaf,
        :sample_vmaf,
        :dash_vmaf,
        :eta_vmaf,
        :vmaf_comparison,
        :progress,
        :success,
        :warning,
        :encoding_start,
        :encoding_progress,
        :encoding_progress_alt,
        :file_size_progress,
        :ffmpeg_error
      ]

      for key <- expected_keys do
        assert Map.has_key?(patterns, key), "Missing expected pattern key: #{key}"
      end
    end

    test "all values are Regex structs" do
      patterns = OutputParser.get_patterns()

      for {key, value} <- patterns do
        assert %Regex{} = value, "Pattern #{key} is not a Regex struct"
      end
    end
  end

  describe "match_pattern/2" do
    test "matches simple_vmaf pattern and returns string captures" do
      line = "crf 25 VMAF 93.45 (95%)"
      assert {:ok, captures} = OutputParser.match_pattern(line, :simple_vmaf)
      assert captures["crf"] == "25"
      assert captures["score"] == "93.45"
      assert captures["percent"] == "95"
    end

    test "matches success pattern" do
      line = "crf 25 successful"
      assert {:ok, captures} = OutputParser.match_pattern(line, :success)
      assert captures["crf"] == "25"
    end

    test "matches warning pattern" do
      line = "Warning: low bitrate detected"
      assert {:ok, captures} = OutputParser.match_pattern(line, :warning)
      assert captures["message"] == "low bitrate detected"
    end

    test "matches ffmpeg_error pattern" do
      line = "Error: ffmpeg encode exit code 137"
      assert {:ok, captures} = OutputParser.match_pattern(line, :ffmpeg_error)
      assert captures["exit_code"] == "137"
    end

    test "returns error for non-matching line" do
      line = "this is just some random output"
      assert {:error, :no_match} = OutputParser.match_pattern(line, :simple_vmaf)
    end

    test "returns error for empty line" do
      assert {:error, :no_match} = OutputParser.match_pattern("", :simple_vmaf)
    end
  end

  describe "parse_line/1 - vmaf result patterns" do
    test "parses simple_vmaf line into vmaf_result" do
      line = "crf 25 VMAF 93.45 (95%)"
      assert {:ok, result} = OutputParser.parse_line(line)
      assert result.type == :vmaf_result
      assert result.data.crf == 25.0
      assert result.data.vmaf_score == 93.45
      assert result.data.percent == 95
    end

    test "parses simple_vmaf with decimal crf" do
      line = "crf 25.5 VMAF 91.23 (90%)"
      assert {:ok, result} = OutputParser.parse_line(line)
      assert result.type == :vmaf_result
      assert result.data.crf == 25.5
      assert result.data.vmaf_score == 91.23
    end

    test "sample_vmaf line resolves as vmaf_result because simple_vmaf has priority" do
      # simple_vmaf fires before sample_vmaf in parse_line/1 pattern order,
      # since "crf X VMAF X.XX (X%)" is a substring of any sample_vmaf line.
      # Use match_pattern/2 directly to test the sample_vmaf pattern itself.
      line = "sample 3/10 crf 25 VMAF 93.45 (95%)"
      assert {:ok, result} = OutputParser.parse_line(line)
      assert result.type == :vmaf_result
      assert result.data.crf == 25.0
      assert result.data.vmaf_score == 93.45
    end

    test "match_pattern/2 with sample_vmaf captures sample numbers" do
      line = "sample 3/10 crf 25 VMAF 93.45 (95%)"
      assert {:ok, captures} = OutputParser.match_pattern(line, :sample_vmaf)
      assert captures["sample_num"] == "3"
      assert captures["total_samples"] == "10"
      assert captures["crf"] == "25"
      assert captures["score"] == "93.45"
    end

    test "dash_vmaf line resolves as vmaf_result because simple_vmaf has priority" do
      # simple_vmaf fires before dash_vmaf in parse_line/1; the crf/VMAF portion
      # is matched as a simple_vmaf substring match.
      line = "- crf 25 VMAF 93.45 (95%)"
      assert {:ok, result} = OutputParser.parse_line(line)
      assert result.type == :vmaf_result
      assert result.data.crf == 25.0
      assert result.data.vmaf_score == 93.45
    end

    test "match_pattern/2 with dash_vmaf captures crf and score" do
      line = "- crf 25 VMAF 93.45 (95%)"
      assert {:ok, captures} = OutputParser.match_pattern(line, :dash_vmaf)
      assert captures["crf"] == "25"
      assert captures["score"] == "93.45"
      assert captures["percent"] == "95"
    end

    test "parses eta_vmaf line into eta_vmaf" do
      line = "crf 25 VMAF 93.45 predicted video stream size 1.5 GB (95%) taking 30 seconds"
      assert {:ok, result} = OutputParser.parse_line(line)
      assert result.type == :eta_vmaf
      assert result.data.crf == 25.0
      assert result.data.vmaf_score == 93.45
      assert result.data.predicted_size == 1.5
      assert result.data.size_unit == "GB"
      assert result.data.percent == 95
    end
  end

  describe "parse_line/1 - encoding sample patterns" do
    test "parses encoding_sample line" do
      line = "encoding sample 1/10 crf 25"
      assert {:ok, result} = OutputParser.parse_line(line)
      assert result.type == :encoding_sample
      assert result.data.sample_num == 1
      assert result.data.total_samples == 10
      assert result.data.crf == 25.0
    end

    test "parses encoding_sample with decimal crf" do
      line = "encoding sample 5/10 crf 28.5"
      assert {:ok, result} = OutputParser.parse_line(line)
      assert result.type == :encoding_sample
      assert result.data.crf == 28.5
    end
  end

  describe "parse_line/1 - progress patterns" do
    test "parses progress line" do
      line = "[2024-01-01T00:00:00] 42%, 24.5 fps, eta 2 minutes"
      assert {:ok, result} = OutputParser.parse_line(line)
      assert result.type == :progress
      assert result.data.progress == 42.0
      assert result.data.fps == 24.5
      assert result.data.eta == 2
      assert result.data.eta_unit == "minute"
    end

    test "parses encoding_start line" do
      line = "[2024-01-01T00:00:00] encoding 123.mkv"
      assert {:ok, result} = OutputParser.parse_line(line)
      assert result.type == :encoding_start
      assert result.data.video_id == 123
      assert result.data.filename == "123.mkv"
    end

    test "parses encoding_start with mp4 file" do
      line = "[timestamp] encoding 456.mp4"
      assert {:ok, result} = OutputParser.parse_line(line)
      assert result.type == :encoding_start
      assert result.data.video_id == 456
    end

    test "timestamped progress line resolves as :progress type (fires before encoding_progress)" do
      # The :progress pattern matches before :encoding_progress in parse_line/1.
      # Both patterns match timestamped progress lines; :progress takes priority.
      line = "[2024-01-01T00:00:00] 50%, 24.5 fps, eta 1 seconds"
      assert {:ok, result} = OutputParser.parse_line(line)
      assert result.type == :progress
      assert result.data.progress == 50.0
      assert result.data.fps == 24.5
      assert result.data.eta == 1
    end

    test "parses encoding_progress_alt line without timestamp" do
      line = "75%, 30.0 fps, eta 45 seconds"
      assert {:ok, result} = OutputParser.parse_line(line)
      assert result.type == :encoding_progress
      assert result.data.percent == 75
      assert result.data.fps == 30.0
      assert result.data.eta == 45
    end

    test "parses file_size_progress line" do
      line = "Encoded 1.5 GB (50%)"
      assert {:ok, result} = OutputParser.parse_line(line)
      assert result.type == :file_size_progress
      assert result.data.encoded_size == "1.5 GB"
      assert result.data.percent == 50
    end
  end

  describe "parse_line/1 - status patterns" do
    test "parses success line" do
      line = "crf 25 successful"
      assert {:ok, result} = OutputParser.parse_line(line)
      assert result.type == :success
      assert result.data.crf == 25.0
    end

    test "parses success line with decimal crf" do
      line = "crf 28.5 successful"
      assert {:ok, result} = OutputParser.parse_line(line)
      assert result.type == :success
      assert result.data.crf == 28.5
    end

    test "parses warning line" do
      line = "Warning: content may have high grain"
      assert {:ok, result} = OutputParser.parse_line(line)
      assert result.type == :warning
      assert result.data.message == "content may have high grain"
    end

    test "parses ffmpeg_error line" do
      line = "Error: ffmpeg encode exit code 1"
      assert {:ok, result} = OutputParser.parse_line(line)
      assert result.type == :ffmpeg_error
      assert result.data.exit_code == 1
    end

    test "parses ffmpeg_error with non-zero exit code" do
      line = "Error: ffmpeg encode exit code 255"
      assert {:ok, result} = OutputParser.parse_line(line)
      assert result.type == :ffmpeg_error
      assert result.data.exit_code == 255
    end
  end

  describe "parse_line/1 - no match cases" do
    test "returns error for empty line" do
      assert {:error, :no_match} = OutputParser.parse_line("")
    end

    test "returns error for whitespace-only line" do
      assert {:error, :no_match} = OutputParser.parse_line("   ")
    end

    test "returns error for unrecognized output" do
      assert {:error, :no_match} = OutputParser.parse_line("random debug output")
    end

    test "returns error for partial matches" do
      assert {:error, :no_match} = OutputParser.parse_line("crf 25 without vmaf")
    end

    test "returns error for a log line that does not match any pattern" do
      assert {:error, :no_match} =
               OutputParser.parse_line("[info] Starting ab-av1 process with args")
    end
  end

  describe "parse_output/1 - with string input" do
    test "splits and parses multi-line string" do
      output = """
      crf 25 VMAF 93.45 (95%)
      some random line
      crf 25 successful
      """

      results = OutputParser.parse_output(output)
      assert length(results) == 2
      types = Enum.map(results, & &1.type)
      assert :vmaf_result in types
      assert :success in types
    end

    test "returns empty list for string with no recognized lines" do
      output = "nothing here\nstill nothing\n"
      assert OutputParser.parse_output(output) == []
    end

    test "parses a single-line string" do
      output = "crf 30 VMAF 95.0 (100%)\n"
      results = OutputParser.parse_output(output)
      assert length(results) == 1
      assert hd(results).type == :vmaf_result
    end
  end

  describe "parse_output/1 - with list input" do
    test "parses list of lines and filters unrecognized" do
      lines = [
        "encoding sample 1/10 crf 25",
        "irrelevant line",
        "crf 25 VMAF 93.45 (95%)",
        "another irrelevant line",
        "crf 25 successful"
      ]

      results = OutputParser.parse_output(lines)
      assert length(results) == 3
      types = Enum.map(results, & &1.type)
      assert :encoding_sample in types
      assert :vmaf_result in types
      assert :success in types
    end

    test "returns empty list for list with no recognized lines" do
      lines = ["debug info", "internal state", "trace output"]
      assert OutputParser.parse_output(lines) == []
    end

    test "handles empty list" do
      assert OutputParser.parse_output([]) == []
    end

    test "handles list with only empty strings" do
      lines = ["", "  ", "\t"]
      assert OutputParser.parse_output(lines) == []
    end
  end
end
