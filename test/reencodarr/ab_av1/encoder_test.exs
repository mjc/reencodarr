defmodule Reencodarr.AbAv1.EncoderTest do
  @moduledoc """
  Tests for the Encoder port-holder GenServer public API.

  Covers the "not running" code paths of every public function, plus
  child_spec/1 which is a pure function.
  """
  use Reencodarr.UnitCase, async: true

  alias Reencodarr.AbAv1.Encoder

  describe "child_spec/1" do
    test "returns a valid child spec map" do
      args = ["encode", "--crf", "28", "input.mkv"]
      metadata = %{video_id: 1, output_file: "/tmp/out.mkv"}

      spec = Encoder.child_spec({args, metadata})

      assert spec.id == Reencodarr.AbAv1.Encoder
      assert spec.restart == :temporary
      assert spec.type == :worker
      assert {Reencodarr.AbAv1.Encoder, :start_link, [^args, ^metadata]} = spec.start
    end

    test "passes empty args and metadata through" do
      spec = Encoder.child_spec({[], %{}})

      assert {Reencodarr.AbAv1.Encoder, :start_link, [[], %{}]} = spec.start
    end

    test "preserves complex metadata" do
      metadata = %{
        video_id: 42,
        vmaf: 95.0,
        output_file: "/media/out.mkv",
        encode_args: ["--preset", "4"]
      }

      spec = Encoder.child_spec({["encode"], metadata})

      assert {_, :start_link, [["encode"], ^metadata]} = spec.start
    end
  end

  describe "running?/0 when not started" do
    test "returns false" do
      refute Encoder.running?()
    end
  end

  describe "subscribe/1 when not started" do
    test "returns {:error, :not_running}" do
      assert {:error, :not_running} = Encoder.subscribe(self())
    end

    test "returns {:error, :not_running} for any pid" do
      {:ok, agent} = Agent.start_link(fn -> nil end)
      assert {:error, :not_running} = Encoder.subscribe(agent)
      Agent.stop(agent)
    end
  end

  describe "get_metadata/0 when not started" do
    test "returns {:error, :not_running}" do
      assert {:error, :not_running} = Encoder.get_metadata()
    end
  end

  describe "get_os_pid/0 when not started" do
    test "returns {:error, :not_running}" do
      assert {:error, :not_running} = Encoder.get_os_pid()
    end
  end

  describe "kill/0 when not started" do
    test "returns :ok (noop)" do
      assert :ok = Encoder.kill()
    end
  end
end
