defmodule Reencodarr.ApplicationWorkersTest do
  use ExUnit.Case, async: false

  alias Reencodarr.AbAv1.LocalWorker

  setup do
    previous = Application.get_env(:reencodarr, :crf_execution_mode)
    previous_supervise = Application.get_env(:reencodarr, :supervise_local_worker)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:reencodarr, :crf_execution_mode)
      else
        Application.put_env(:reencodarr, :crf_execution_mode, previous)
      end

      if is_nil(previous_supervise) do
        Application.delete_env(:reencodarr, :supervise_local_worker)
      else
        Application.put_env(:reencodarr, :supervise_local_worker, previous_supervise)
      end
    end)
  end

  test "worker mode can leave the worker to an external service" do
    Application.put_env(:reencodarr, :crf_execution_mode, :worker)
    Application.put_env(:reencodarr, :supervise_local_worker, false)

    children = Reencodarr.Application.worker_children(:dev)

    refute LocalWorker in children
    refute Reencodarr.CrfSearcher.Supervisor in children
  end

  test "Broadway mode starts the CRF pipeline but not the local worker" do
    Application.put_env(:reencodarr, :crf_execution_mode, :broadway)
    children = Reencodarr.Application.worker_children(:dev)

    assert Reencodarr.CrfSearcher.Supervisor in children
    refute LocalWorker in children
  end

  test "worker mode starts the local worker but not the CRF Broadway pipeline" do
    Application.put_env(:reencodarr, :crf_execution_mode, :worker)
    children = Reencodarr.Application.worker_children(:dev)

    assert LocalWorker in children
    refute Reencodarr.CrfSearcher.Supervisor in children

    assert Reencodarr.Analyzer.Supervisor in children
    assert Reencodarr.Encoder.Supervisor in children
    assert Reencodarr.Dashboard.State in children
    assert Reencodarr.TempCleaner in children
  end
end
