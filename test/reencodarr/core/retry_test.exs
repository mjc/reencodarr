defmodule Reencodarr.Core.RetryTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

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

    test "retries interrupted sqlite errors" do
      test_pid = self()
      attempts = :atomics.new(1, [])

      assert :ok =
               Retry.retry_on_db_busy(fn ->
                 attempt = :atomics.add_get(attempts, 1, 1)
                 send(test_pid, {:retry_attempt, attempt})

                 if attempt == 1 do
                   raise Exqlite.Error, message: "interrupted"
                 end

                 :ok
               end)

      assert_receive {:retry_attempt, 1}
      assert_receive {:retry_attempt, 2}
    end

    test "includes operation label in retry log" do
      log =
        capture_log(fn ->
          assert :ok = retry_once_with_busy(label: "mark video as analyzed")
        end)

      assert log =~ "SQLite transient error during mark video as analyzed"
      assert log =~ "caller Reencodarr.Core.RetryTest."
    end
  end

  defp retry_once_with_busy(opts) do
    attempts = :atomics.new(1, [])

    Retry.retry_on_db_busy(
      fn ->
        if :atomics.add_get(attempts, 1, 1) == 1 do
          raise Exqlite.Error, message: "database busy"
        end

        :ok
      end,
      Keyword.put_new(opts, :base_backoff_ms, 1)
    )
  end
end
