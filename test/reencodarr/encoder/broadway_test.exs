defmodule Reencodarr.Encoder.BroadwayTest do
  use Reencodarr.UnitCase, async: true

  alias Reencodarr.Encoder.Broadway

  describe "transform/2" do
    test "transforms VMAF data into Broadway message" do
      vmaf = %{id: 1, video: %{path: "/path/to/video.mp4"}}

      message = Broadway.transform(vmaf, [])

      # Check that it's a Broadway Message struct and contains the data
      assert %{data: ^vmaf} = message
      assert is_struct(message)
    end

    test "transform wraps data in a struct with correct data field" do
      vmaf = %{id: 99, crf: 24, video: %{path: "/movies/a.mkv"}}
      message = Broadway.transform(vmaf, extra: :opts)
      assert is_struct(message)
      assert message.data == vmaf
    end
  end

  describe "running?/0" do
    test "returns false when pipeline is not started (test env)" do
      # In test environment, Encoder Broadway is not started
      refute Broadway.running?()
    end
  end

  describe "pause/0, resume/0, start/0" do
    test "pause returns :ok" do
      assert :ok = Broadway.pause()
    end

    test "resume returns :ok" do
      assert :ok = Broadway.resume()
    end

    test "start returns :ok" do
      assert :ok = Broadway.start()
    end
  end

  describe "filter_input_output_args_for_test/1" do
    test "removes --input flag and its value" do
      args = ["--input", "/path/to/input.mkv", "--crf", "24"]
      result = Broadway.filter_input_output_args_for_test(args)
      assert "--input" not in result
      assert "/path/to/input.mkv" not in result
      assert "--crf" in result
      assert "24" in result
    end

    test "removes --output flag and its value" do
      args = ["--output", "/path/to/output.mkv", "--preset", "4"]
      result = Broadway.filter_input_output_args_for_test(args)
      assert "--output" not in result
      assert "/path/to/output.mkv" not in result
      assert "--preset" in result
      assert "4" in result
    end

    test "removes -i and -o short flags and their values" do
      args = ["-i", "input.mkv", "-o", "output.mkv", "--vmaf", "95"]
      result = Broadway.filter_input_output_args_for_test(args)
      assert "-i" not in result
      assert "input.mkv" not in result
      assert "-o" not in result
      assert "output.mkv" not in result
      assert "--vmaf" in result
      assert "95" in result
    end

    test "passes through args with no input/output flags" do
      args = ["encode", "--crf", "28", "--preset", "6"]
      result = Broadway.filter_input_output_args_for_test(args)
      assert result == args
    end

    test "handles empty args list" do
      assert [] = Broadway.filter_input_output_args_for_test([])
    end

    test "preserves order of remaining args" do
      args = ["--crf", "24", "--input", "/a.mkv", "--preset", "4"]
      result = Broadway.filter_input_output_args_for_test(args)
      assert result == ["--crf", "24", "--preset", "4"]
    end
  end
end
