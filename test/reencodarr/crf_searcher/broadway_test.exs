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
  end
end
