defmodule Reencodarr.AbAv1.WorkerConfigTest do
  use ExUnit.Case, async: false

  alias Reencodarr.AbAv1.WorkerConfig

  setup do
    keys = [
      :crf_execution_mode,
      :worker_connect_url,
      :worker_executable,
      :worker_id,
      :worker_extra_args,
      :worker_token
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:reencodarr, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:reencodarr, key)
        {key, value} -> Application.put_env(:reencodarr, key, value)
      end)
    end)

    :ok
  end

  test "can enable and disable distributed workers" do
    previous = Application.get_env(:reencodarr, :distributed_worker_enabled)

    try do
      assert :ok = WorkerConfig.enable()
      assert WorkerConfig.enabled?()

      assert :ok = WorkerConfig.disable()
      refute WorkerConfig.enabled?()
    after
      if is_nil(previous) do
        Application.delete_env(:reencodarr, :distributed_worker_enabled)
      else
        Application.put_env(:reencodarr, :distributed_worker_enabled, previous)
      end
    end
  end

  test "defaults CRF execution to Broadway and accepts worker mode" do
    Application.delete_env(:reencodarr, :crf_execution_mode)
    assert WorkerConfig.execution_mode() == :broadway

    Application.put_env(:reencodarr, :crf_execution_mode, "worker")
    assert WorkerConfig.execution_mode() == :worker
  end

  test "rejects an unknown CRF execution mode" do
    Application.put_env(:reencodarr, :crf_execution_mode, "both")

    assert_raise ArgumentError, ~r/CRF execution mode/, fn ->
      WorkerConfig.execution_mode()
    end
  end

  test "builds local worker configuration without exposing the token in diagnostics" do
    Application.put_env(:reencodarr, :worker_connect_url, "http://127.0.0.1:4000/")
    Application.put_env(:reencodarr, :worker_executable, "/bin/ab-av1-worker")
    Application.put_env(:reencodarr, :worker_id, "living-room")
    Application.put_env(:reencodarr, :worker_extra_args, ["--once"])
    Application.put_env(:reencodarr, :worker_token, "secret-token")

    assert %{
             connect_url: "http://127.0.0.1:4000",
             executable: "/bin/ab-av1-worker",
             worker_id: "living-room",
             extra_args: ["--once"],
             token: "secret-token"
           } = WorkerConfig.local_worker_config!()
  end
end
