defmodule Reencodarr.CrfSearcher.BroadwayTest do
  use ExUnit.Case, async: true

  alias Reencodarr.CrfSearcher.Broadway

  describe "transform/2" do
    test "transforms video data into Broadway message" do
      video = %{id: 1, path: "/path/to/video.mp4"}

      message = Broadway.transform(video, [])

      # Check that it's a Broadway Message struct and contains the data
      assert %{data: ^video} = message
      assert is_struct(message)
    end

    test "transform wraps data in a Broadway.Message struct" do
      data = %{id: 42, crf: 28}
      message = Broadway.transform(data, some: :opts)
      assert is_struct(message)
      assert message.data == data
    end
  end

  describe "running?/0" do
    test "returns false when pipeline is not started (test env)" do
      # In test environment, CrfSearcher is not started
      refute Broadway.running?()
    end
  end

  describe "pause/0" do
    test "pause returns :ok" do
      # Pause is a no-op in test env (supervisor not started)
      import ExUnit.CaptureLog
      _log = capture_log(fn -> assert :ok = Broadway.pause() end)
    end
  end
end
