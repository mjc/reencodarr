defmodule Reencodarr.DbWriterTest do
  use Reencodarr.DataCase, async: false

  import ExUnit.CaptureLog

  alias Reencodarr.DbWriter

  test "run executes inline in test and returns the function result" do
    refute DbWriter.in_writer?()

    result =
      DbWriter.run(fn ->
        assert DbWriter.in_writer?()
        :ok
      end)

    assert result == :ok
    refute DbWriter.in_writer?()
  end

  test "nested run executes inline without deadlocking" do
    assert :nested =
             DbWriter.run(fn ->
               assert DbWriter.in_writer?()

               DbWriter.run(fn ->
                 assert DbWriter.in_writer?()
                 :nested
               end)
             end)
  end

  test "enqueue executes immediately in test" do
    test_pid = self()

    assert :ok =
             DbWriter.enqueue(fn ->
               send(test_pid, :enqueued)
             end)

    assert_receive :enqueued
  end

  test "inline enqueue logs failures without crashing the caller" do
    log =
      capture_log(fn ->
        assert :ok =
                 DbWriter.enqueue(
                   fn ->
                     raise "boom"
                   end,
                   label: :inline_failing_job
                 )
      end)

    assert log =~ "DbWriter async task failed for :inline_failing_job"
    assert log =~ "RuntimeError"
    assert log =~ "boom"
  end

  test "transaction preserves Repo.transaction semantics" do
    assert {:ok, :committed} =
             DbWriter.transaction(fn ->
               :committed
             end)

    assert {:error, :rolled_back} =
             DbWriter.transaction(fn ->
               Repo.rollback(:rolled_back)
             end)
  end

  test "run uses writer_timeout without consuming Repo timeout options" do
    test_pid = self()

    task =
      Task.async(fn ->
        DbWriter.run(
          fn ->
            send(test_pid, :writer_entered)

            receive do
              :release_writer -> :occupied
            end
          end,
          inline?: false,
          writer_timeout: 1_000
        )
      end)

    assert_receive :writer_entered

    available_task =
      Task.async(fn ->
        DbWriter.run(
          fn -> :available end,
          inline?: false,
          timeout: 1,
          writer_timeout: 1_000
        )
      end)

    send(Process.whereis(DbWriter), :release_writer)

    assert Task.await(available_task) == :available
    assert Task.await(task) == :occupied
  end

  test "enqueue logs async failures with the writer label" do
    log =
      capture_log(fn ->
        assert :ok =
                 DbWriter.enqueue(
                   fn ->
                     raise "boom"
                   end,
                   inline?: false,
                   label: :failing_job
                 )

        assert :barrier =
                 DbWriter.run(
                   fn ->
                     :barrier
                   end,
                   inline?: false
                 )
      end)

    assert log =~ "DbWriter async task failed for :failing_job"
    assert log =~ "RuntimeError"
    assert log =~ "boom"
  end
end
