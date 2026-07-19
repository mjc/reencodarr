defmodule Reencodarr.AbAv1.LocalWorkerTest do
  use Reencodarr.DataCase, async: false

  alias Reencodarr.AbAv1.LocalWorker
  alias Reencodarr.Fixtures
  alias Reencodarr.Media

  test "launches ab-av1 worker and reports sanitized process status" do
    {:ok, orphan} = Fixtures.video_fixture(%{state: :crf_searching})

    {:ok, dispatched} =
      Fixtures.video_fixture(%{
        state: :crf_searching,
        crf_search_worker_id: "existing-worker"
      })

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "reencodarr-local-worker-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    executable = Path.join(tmp_dir, "ab-av1")
    capture_path = Path.join(tmp_dir, "args")

    File.write!(executable, """
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      echo "ab-av1 0.11.4-worker"
      exit 0
    fi
    pwd > "$REENCODARR_TEST_CAPTURE"
    printf '%s\n' "$@" >> "$REENCODARR_TEST_CAPTURE"
    while true; do sleep 1; done
    """)

    File.chmod!(executable, 0o755)
    previous_capture = System.get_env("REENCODARR_TEST_CAPTURE")
    System.put_env("REENCODARR_TEST_CAPTURE", capture_path)

    on_exit(fn ->
      if previous_capture,
        do: System.put_env("REENCODARR_TEST_CAPTURE", previous_capture),
        else: System.delete_env("REENCODARR_TEST_CAPTURE")

      File.rm_rf!(tmp_dir)
    end)

    {:ok, pid} =
      start_supervised(
        {LocalWorker,
         name: nil,
         config: %{
           executable: executable,
           connect_url: "http://127.0.0.1:4000",
           token: "top-secret",
           worker_id: "test-worker",
           work_dir: tmp_dir,
           extra_args: ["--once"]
         }}
      )

    assert eventually(fn -> File.exists?(capture_path) end)

    assert %{
             running: true,
             executable: ^executable,
             connect_url: "http://127.0.0.1:4000",
             worker_id: "test-worker",
             version: "ab-av1 0.11.4-worker",
             restart_count: 0
           } = LocalWorker.status(pid)

    refute inspect(LocalWorker.status(pid)) =~ "top-secret"

    assert File.read!(capture_path) ==
             "#{tmp_dir}\nworker\n--connect\nhttp://127.0.0.1:4000\n--token\ntop-secret\n--worker-id\ntest-worker\n--protocol-version\n1\n--once\n"

    assert Media.get_video(orphan.id).state == :analyzed
    assert Media.get_video(dispatched.id).state == :crf_searching
    assert Media.get_video(dispatched.id).crf_search_worker_id == "existing-worker"

    os_pid = LocalWorker.status(pid).os_pid
    assert :ok = stop_supervised(LocalWorker)
    refute os_process_alive?(os_pid)
  end

  test "restarts an unexpectedly exited worker with bounded backoff" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "reencodarr-local-worker-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    executable = Path.join(tmp_dir, "ab-av1")
    counter_path = Path.join(tmp_dir, "starts")

    File.write!(executable, """
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      echo "ab-av1 test-worker"
      exit 0
    fi
    count=0
    [ -f "$REENCODARR_TEST_COUNTER" ] && count="$(cat "$REENCODARR_TEST_COUNTER")"
    count=$((count + 1))
    printf '%s' "$count" > "$REENCODARR_TEST_COUNTER"
    [ "$count" -eq 1 ] && exit 23
    while true; do sleep 1; done
    """)

    File.chmod!(executable, 0o755)
    previous_counter = System.get_env("REENCODARR_TEST_COUNTER")
    System.put_env("REENCODARR_TEST_COUNTER", counter_path)

    on_exit(fn ->
      if previous_counter,
        do: System.put_env("REENCODARR_TEST_COUNTER", previous_counter),
        else: System.delete_env("REENCODARR_TEST_COUNTER")

      File.rm_rf!(tmp_dir)
    end)

    {:ok, pid} =
      start_supervised(
        {LocalWorker,
         name: nil,
         config: %{
           executable: executable,
           connect_url: "http://127.0.0.1:4000",
           token: "secret",
           worker_id: "restart-test",
           extra_args: [],
           restart_base_ms: 10,
           restart_max_ms: 20
         }}
      )

    assert eventually(fn ->
             status = LocalWorker.status(pid)
             status.running and status.restart_count == 1 and status.last_exit_status == 23
           end)

    assert eventually(fn -> File.read(counter_path) == {:ok, "2"} end)

    os_pid = LocalWorker.status(pid).os_pid
    assert :ok = stop_supervised(LocalWorker)
    refute os_process_alive?(os_pid)
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp os_process_alive?(pid) do
    case System.find_executable("kill") do
      nil ->
        false

      executable ->
        match?(
          {_output, 0},
          System.cmd(executable, ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
        )
    end
  end
end
