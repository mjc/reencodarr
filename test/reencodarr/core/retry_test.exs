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

  describe "safe_port_close/1" do
    test "returns :ok for :none" do
      assert Retry.safe_port_close(:none) == :ok
    end

    test "returns :ok for already-closed port" do
      port = Port.open({:spawn, "echo test"}, [:binary])
      Port.close(port)

      assert Retry.safe_port_close(port) == :ok
    end
  end

  describe "safe_persistent_term_erase/1" do
    test "erases existing key" do
      key = {:test_erase, System.unique_integer()}
      :persistent_term.put(key, "value")

      assert Retry.safe_persistent_term_erase(key) == :ok
      assert :persistent_term.get(key, nil) == nil
    end

    test "returns :ok for non-existent key" do
      key = {:test_erase, System.unique_integer()}
      assert Retry.safe_persistent_term_erase(key) == :ok
    end
  end
end
