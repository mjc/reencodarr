defmodule Reencodarr.EncoderTest do
  use Reencodarr.DataCase, async: false

  alias Reencodarr.AbAv1.WorkerSessions
  alias Reencodarr.AbAv1.WorkerSessions.Job
  alias Reencodarr.Encoder

  setup do
    previous = Application.get_env(:reencodarr, :crf_execution_mode)
    Application.put_env(:reencodarr, :crf_execution_mode, :worker)
    WorkerSessions.reset()

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:reencodarr, :crf_execution_mode),
        else: Application.put_env(:reencodarr, :crf_execution_mode, previous)
    end)

    :ok
  end

  test "reports an active worker encode as processing" do
    assert {:ok, _session} =
             WorkerSessions.register(%{
               server_worker_id: "server-encode",
               client_worker_id: "worker-encode",
               protocol_version: 1,
               version: "0.11.4",
               capabilities: %{"encode" => true}
             })

    assert {:ok, _session} =
             WorkerSessions.assign_job("server-encode", %Job{
               job_id: "encode-1",
               job_type: :encode,
               video_id: 1,
               phase: :encoding
             })

    assert %{actively_running: true, available: :processing} = Encoder.status()
  end

  test "reports idle when no worker encode exists" do
    assert %{actively_running: false, available: :available} = Encoder.status()
  end
end
