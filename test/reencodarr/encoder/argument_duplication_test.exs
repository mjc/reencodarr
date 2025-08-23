defmodule Reencodarr.Encoder.ArgumentDuplicationTest do
  use ExUnit.Case, async: true

  alias Reencodarr.AbAv1.Encode

  describe "build_encode_args/1" do
    test "does not duplicate input/output arguments when present in vmaf params" do
      # Create a VMAF struct with params that include input/output
      vmaf = %{
        video: %{path: "/path/to/input.mkv", id: 123},
        crf: 23.0,
        params: [
          "--input",
          "/path/to/input.mkv",
          "--output",
          "/path/to/output.mkv",
          "--preset",
          "slow"
        ]
      }

      args = Encode.build_encode_args_for_test(vmaf)

      # Count occurrences of input/output flags
      input_count = Enum.count(args, &(&1 == "--input"))
      output_count = Enum.count(args, &(&1 == "--output"))

      # Should only have one occurrence of each
      assert input_count == 1,
             "Expected 1 --input flag, got #{input_count}. Args: #{inspect(args)}"

      assert output_count == 1,
             "Expected 1 --output flag, got #{output_count}. Args: #{inspect(args)}"

      # Verify the correct base structure is preserved
      assert Enum.at(args, 0) == "encode"
      assert Enum.at(args, 1) == "--crf"
      assert Enum.at(args, 2) == "23.0"
      assert Enum.at(args, 3) == "--output"
      assert String.contains?(Enum.at(args, 4), "123.mkv")
      assert Enum.at(args, 5) == "--input"
      assert Enum.at(args, 6) == "/path/to/input.mkv"

      # Verify other params are still included
      assert "--preset" in args
      assert "slow" in args
    end

    test "filter_input_output_args removes input/output flags and their values" do
      args = [
        "--preset",
        "slow",
        "--input",
        "/path/input.mkv",
        "--crf",
        "23",
        "--output",
        "/path/output.mkv",
        "--speed",
        "4"
      ]

      filtered = Encode.filter_input_output_args_for_test(args)

      # Should not contain input/output flags or their values
      refute "--input" in filtered
      refute "/path/input.mkv" in filtered
      refute "--output" in filtered
      refute "/path/output.mkv" in filtered

      # Should still contain other flags and values
      assert "--preset" in filtered
      assert "slow" in filtered
      assert "--crf" in filtered
      assert "23" in filtered
      assert "--speed" in filtered
      assert "4" in filtered
    end

    test "filter_input_output_args handles short form flags" do
      args = [
        "--preset",
        "slow",
        "-i",
        "/path/input.mkv",
        "--crf",
        "23",
        "-o",
        "/path/output.mkv"
      ]

      filtered = Encode.filter_input_output_args_for_test(args)

      # Should not contain short form input/output flags or their values
      refute "-i" in filtered
      refute "/path/input.mkv" in filtered
      refute "-o" in filtered
      refute "/path/output.mkv" in filtered

      # Should still contain other flags and values
      assert "--preset" in filtered
      assert "slow" in filtered
      assert "--crf" in filtered
      assert "23" in filtered
    end

    test "build_encode_args works correctly when vmaf params is nil" do
      vmaf = %{
        video: %{path: "/path/to/input.mkv", id: 123},
        crf: 23.0,
        params: nil
      }

      args = Encode.build_encode_args_for_test(vmaf)

      # Should still have the base structure
      input_count = Enum.count(args, &(&1 == "--input"))
      output_count = Enum.count(args, &(&1 == "--output"))

      assert input_count == 1
      assert output_count == 1
    end

    test "build_encode_args works correctly when vmaf params is empty list" do
      vmaf = %{
        video: %{path: "/path/to/input.mkv", id: 123},
        crf: 23.0,
        params: []
      }

      args = Encode.build_encode_args_for_test(vmaf)

      # Should still have the base structure
      input_count = Enum.count(args, &(&1 == "--input"))
      output_count = Enum.count(args, &(&1 == "--output"))

      assert input_count == 1
      assert output_count == 1
    end
  end
end
