defmodule Reencodarr.AbAv1.EncodeTest do
  use Reencodarr.DataCase, async: false

  alias Reencodarr.AbAv1.Encode

  describe "encode availability" do
    setup do
      {:ok, pid} = Encode.start_link([])
      %{pid: pid}
    end

    test "GenServer starts with port :none and is available", %{pid: _pid} do
      state = :sys.get_state(Encode)
      assert state.port == :none
      assert Encode.available?() == true
    end
  end

  # Note: Full port opening error handling tests require Vmaf structs from the database.
  # These are covered by integration tests.
  # The key fix is already implemented: Helper.open_port returns {:ok, port} | {:error, :not_found}
  # and the Encode module's start_encode_port/2 handles both cases gracefully.
end
