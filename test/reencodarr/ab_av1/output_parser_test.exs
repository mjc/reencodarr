defmodule Reencodarr.AbAv1.OutputParserTest do
  @moduledoc """
  Tests for ab-av1 output parsing patterns and structured data extraction.
  This module tests the core pattern matching logic that was moved from CrfSearch.
  """
  use ExUnit.Case, async: true

  alias Reencodarr.AbAv1.OutputParser

  describe "parse_line/1" do
    test "parses sample VMAF results" do
      line = "sample 1/5 crf 28 VMAF 91.33 (85%)"

      assert {:ok, %{type: :sample_vmaf, data: data}} = OutputParser.parse_line(line)
      assert data.sample_num == 1
      assert data.total_samples == 5
      assert data.crf == 28.0
      assert data.score == 91.33
      assert data.percent == 85
    end

    test "parses ETA VMAF with size and time" do
      line = "crf 28 VMAF 91.33 predicted video stream size 800.5 MB (85%) taking 120 seconds"

      assert {:ok, %{type: :eta_vmaf, data: data}} = OutputParser.parse_line(line)
      assert data.crf == 28.0
      assert data.score == 91.33
      assert data.size == 800.5
      assert data.unit == "MB"
      assert data.percent == 85
      assert data.time == 120.0
      assert data.time_unit == "seconds"
    end

    test "parses encoding sample lines" do
      line = "encoding sample 2/3 crf 25"

      assert {:ok, %{type: :encoding_sample, data: data}} = OutputParser.parse_line(line)
      assert data.sample_num == 2
      assert data.total_samples == 3
      assert data.crf == 25.0
    end

    test "parses progress lines with timestamp" do
      line = "[2024-12-12T00:13:08Z INFO] 75%, 45.2 fps, eta 5 minutes"

      assert {:ok, %{type: :progress, data: data}} = OutputParser.parse_line(line)
      assert data.progress == 75.0
      assert data.fps == 45.2
      assert data.eta == 5
      assert data.eta_unit == "minute"
    end

    test "parses file progress lines with size information" do
      line = "Encoded 2.5 GB (75%)"

      assert {:ok, %{type: :file_progress, data: data}} = OutputParser.parse_line(line)
      assert data.size == 2.5
      assert data.unit == "GB"
      assert data.progress == 75
    end

    test "parses file progress with different units" do
      # Test MB format
      line = "Encoded 800 MB (50%)"
      assert {:ok, %{type: :file_progress, data: data}} = OutputParser.parse_line(line)
      assert data.size == 800.0
      assert data.unit == "MB"
      assert data.progress == 50

      # Test TB format
      line = "Encoded 1.2 TB (90%)"
      assert {:ok, %{type: :file_progress, data: data}} = OutputParser.parse_line(line)
      assert data.size == 1.2
      assert data.unit == "TB"
      assert data.progress == 90
    end

    test "parses success lines" do
      line = "crf 24 successful"

      assert {:ok, %{type: :success, data: data}} = OutputParser.parse_line(line)
      assert data.crf == 24.0
    end

    test "parses warning lines" do
      line = "Warning: High bitrate detected"

      assert {:ok, %{type: :warning, data: data}} = OutputParser.parse_line(line)
      assert data.message == "High bitrate detected"
    end

    test "returns :ignore for unknown patterns" do
      line = "Random unmatched output"

      assert :ignore = OutputParser.parse_line(line)
    end

    test "handles empty lines" do
      assert :ignore = OutputParser.parse_line("")
      assert :ignore = OutputParser.parse_line("   ")
    end

    test "handles timestamp prefixed VMAF lines" do
      line = "[2024-12-12T00:13:08Z INFO] crf 22 VMAF 94.50 (75%)"

      assert {:ok, %{type: :vmaf_result, data: data}} = OutputParser.parse_line(line)
      assert data.crf == 22.0
      assert data.score == 94.50
      assert data.percent == 75
    end

    test "handles dash-separated VMAF lines" do
      line = "- crf 28 VMAF 90.52 (12%)"

      assert {:ok, %{type: :dash_vmaf, data: data}} = OutputParser.parse_line(line)
      assert data.crf == 28.0
      assert data.score == 90.52
      assert data.percent == 12
    end

    test "parses decimal CRF values" do
      line = "- crf 17.2 VMAF 97.68 (9%)"

      assert {:ok, %{type: :dash_vmaf, data: data}} = OutputParser.parse_line(line)
      assert data.crf == 17.2
      assert data.score == 97.68
      assert data.percent == 9
    end

    test "parses high precision VMAF scores" do
      line = "sample 1/5 crf 28 VMAF 91.334 (85%)"

      assert {:ok, %{type: :sample_vmaf, data: data}} = OutputParser.parse_line(line)
      assert data.crf == 28.0
      assert data.score == 91.334
    end

    test "handles encoding start lines" do
      line = "[2024-12-12T00:13:08Z INFO] encoding 123.mkv"

      assert {:ok, %{type: :encoding_start, data: data}} = OutputParser.parse_line(line)
      assert data.filename == "123.mkv"
      assert data.video_id == 123
    end

    test "handles encoding progress lines" do
      line = "[2024-12-12T00:13:08Z INFO] 42%, 23.5 fps, eta 3 minutes"

      assert {:ok, %{type: :progress, data: data}} = OutputParser.parse_line(line)
      assert data.progress == 42.0
      assert data.fps == 23.5
      assert data.eta == 3
      assert data.eta_unit == "minute"
    end

    test "handles ffmpeg error lines" do
      line = "Error: ffmpeg encode exit code 1"

      assert {:ok, %{type: :ffmpeg_error, data: data}} = OutputParser.parse_line(line)
      assert data.exit_code == 1
    end
  end

  describe "real fixture patterns" do
    setup do
      # Read fixture files if they exist
      crf_search_fixture = Path.join([__DIR__, "..", "..", "fixtures", "crf-search-output.txt"])
      encoding_fixture = Path.join([__DIR__, "..", "..", "fixtures", "encoding-output.txt"])

      crf_search_lines =
        if File.exists?(crf_search_fixture) do
          File.read!(crf_search_fixture)
          |> String.split("\n")
          |> Enum.reject(&(&1 == "" or String.trim(&1) == ""))
        else
          []
        end

      encoding_lines =
        if File.exists?(encoding_fixture) do
          File.read!(encoding_fixture)
          |> String.split("\n")
          |> Enum.reject(&(&1 == "" or String.trim(&1) == ""))
        else
          []
        end

      %{crf_search_lines: crf_search_lines, encoding_lines: encoding_lines}
    end

    test "parses all CRF search fixture lines without error", %{crf_search_lines: lines} do
      # Test that all fixture lines either parse successfully or return :ignore
      Enum.each(lines, fn line ->
        result = OutputParser.parse_line(line)

        assert result == :ignore or match?({:ok, _}, result),
               "Failed to parse line: #{line}"
      end)
    end

    test "parses all encoding fixture lines without error", %{encoding_lines: lines} do
      # Test that all fixture lines either parse successfully or return :ignore
      Enum.each(lines, fn line ->
        result = OutputParser.parse_line(line)

        assert result == :ignore or match?({:ok, _}, result),
               "Failed to parse line: #{line}"
      end)
    end

    test "extracts specific patterns from fixture lines", %{crf_search_lines: lines} do
      # Test that we can find and parse specific expected patterns
      sample_vmaf_line = Enum.find(lines, &String.contains?(&1, "sample 1/5 crf 28 VMAF 91.33"))

      if sample_vmaf_line do
        assert {:ok, %{type: type, data: data}} = OutputParser.parse_line(sample_vmaf_line)
        # Could be either depending on timestamp
        assert type in [:sample_vmaf, :vmaf_result]
        assert data.crf == 28.0
        assert data.score == 91.33
      end

      eta_vmaf_line = Enum.find(lines, &String.contains?(&1, "predicted video stream size"))

      if eta_vmaf_line do
        assert {:ok, %{type: :eta_vmaf, data: _data}} = OutputParser.parse_line(eta_vmaf_line)
      end

      dash_vmaf_line = Enum.find(lines, &String.contains?(&1, "- crf"))

      if dash_vmaf_line do
        assert {:ok, %{type: :dash_vmaf, data: _data}} = OutputParser.parse_line(dash_vmaf_line)
      end

      success_line = Enum.find(lines, &String.contains?(&1, "successful"))

      if success_line do
        assert {:ok, %{type: :success, data: _data}} = OutputParser.parse_line(success_line)
      end
    end

    test "comprehensive fixture coverage analysis", %{crf_search_lines: crf_lines, encoding_lines: enc_lines} do
      # Analyze all fixture lines to ensure comprehensive coverage
      all_lines = crf_lines ++ enc_lines

      # Test every single line in the fixtures
      {parsed_count, ignored_count, pattern_counts} = 
        Enum.reduce(all_lines, {0, 0, %{}}, fn line, {parsed, ignored, patterns} ->
          case OutputParser.parse_line(line) do
            {:ok, %{type: type, data: _data}} ->
              {parsed + 1, ignored, Map.update(patterns, type, 1, &(&1 + 1))}

            :ignore ->
              {parsed, ignored + 1, patterns}
          end
        end)

      # Verify we're actually parsing a significant portion of the fixture data
      total_lines = length(all_lines)
      assert total_lines > 0, "No fixture lines found"
      assert parsed_count > 0, "No lines were successfully parsed"

      # Log the analysis for debugging
      IO.puts "\n=== Fixture Coverage Analysis ==="
      IO.puts "Total fixture lines: #{total_lines}"
      IO.puts "Successfully parsed: #{parsed_count}"
      IO.puts "Ignored lines: #{ignored_count}"
      IO.puts "Parse success rate: #{Float.round(parsed_count / total_lines * 100, 1)}%"
      IO.puts "Pattern counts:"
      Enum.each(pattern_counts, fn {pattern, count} ->
        IO.puts "  #{pattern}: #{count}"
      end)

      # Ensure we're parsing most patterns we expect from ab-av1 output
      found_patterns = Map.keys(pattern_counts)

      # We should find at least some of the expected patterns in the fixtures
      assert length(found_patterns) > 0, "No recognizable patterns found in fixtures"

      # CRF search fixtures should contain sample VMAF and eta VMAF patterns
      if length(crf_lines) > 0 do
        assert Map.has_key?(pattern_counts, :sample_vmaf) or Map.has_key?(pattern_counts, :vmaf_result),
               "CRF search fixtures should contain VMAF patterns"
      end

      # Encoding fixtures should contain encoding-related patterns
      if length(enc_lines) > 0 do
        encoding_patterns = [:encoding_start, :progress, :file_progress]
        has_encoding_pattern = Enum.any?(encoding_patterns, &Map.has_key?(pattern_counts, &1))
        assert has_encoding_pattern, "Encoding fixtures should contain encoding patterns"
      end
    end
  end

  describe "match_pattern/2" do
    test "matches specific patterns directly" do
      line = "sample 2/5 crf 25.5 VMAF 93.45 (67%)"
      captures = OutputParser.match_pattern(line, :sample_vmaf)

      assert captures["sample_num"] == "2"
      assert captures["total_samples"] == "5"
      assert captures["crf"] == "25.5"
      assert captures["score"] == "93.45"
      assert captures["percent"] == "67"
    end

    test "returns nil for non-matching patterns" do
      line = "sample 2/5 crf 25.5 VMAF 93.45 (67%)"
      captures = OutputParser.match_pattern(line, :success)

      assert captures == nil
    end
  end

  describe "parse_output/1" do
    test "parses multiple lines and filters out ignored lines" do
      output = """
      sample 1/5 crf 28 VMAF 91.33 (85%)
      Random unmatched line
      crf 24 successful
      Another random line
      """

      results = OutputParser.parse_output(output)

      assert length(results) == 2
      assert Enum.at(results, 0).type == :sample_vmaf
      assert Enum.at(results, 1).type == :success
    end

    test "handles empty output" do
      results = OutputParser.parse_output("")
      assert results == []
    end

    test "handles list input" do
      lines = [
        "sample 1/5 crf 28 VMAF 91.33 (85%)",
        "crf 24 successful"
      ]

      results = OutputParser.parse_output(lines)

      assert length(results) == 2
      assert Enum.at(results, 0).type == :sample_vmaf
      assert Enum.at(results, 1).type == :success
    end
  end
end
