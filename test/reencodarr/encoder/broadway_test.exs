defmodule Reencodarr.Encoder.BroadwayTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Encoder.Broadway

  describe "transform/2" do
    test "transforms VMAF data into Broadway message" do
      vmaf = %{id: 1, video: %{path: "/path/to/video.mp4"}}

      message = Broadway.transform(vmaf, [])

      # Check that it's a Broadway Message struct and contains the data
      assert %{data: ^vmaf} = message
      assert is_struct(message)
    end
  end
end
