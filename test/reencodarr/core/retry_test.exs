defmodule Reencodarr.Core.RetryTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Core.Retry

  describe "retry_on_db_busy/2" do
    test "returns result when function succeeds on first attempt" do
      assert Retry.retry_on_db_busy(fn -> {:ok, "success"} end) == {:ok, "success"}
    end

    test "returns non-tuple results as-is" do
      assert Retry.retry_on_db_busy(fn -> :ok end) == :ok
      assert Retry.retry_on_db_busy(fn -> 42 end) == 42
    end

    test "re-raises non-busy Exqlite errors" do
      assert_raise Exqlite.Error, "constraint violation", fn ->
        Retry.retry_on_db_busy(fn ->
          raise Exqlite.Error, message: "constraint violation"
        end)
      end
    end
  end
end
