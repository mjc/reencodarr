defmodule Reencodarr.AbAv1.WorkerConfigTest do
  use ExUnit.Case, async: false

  alias Reencodarr.AbAv1.WorkerConfig

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
end
