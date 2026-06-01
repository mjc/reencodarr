defmodule Reencodarr.Media.OrphanResetCountTest do
  use Reencodarr.DataCase

  alias Reencodarr.Media
  alias Reencodarr.Repo

  test "reset_encoder_orphans/0 tolerates nil update counts" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    :meck.new(Repo, [:passthrough])

    on_exit(fn ->
      Agent.stop(calls)

      try do
        :meck.unload(Repo)
      catch
        :error, {:not_mocked, Repo} -> :ok
        :exit, {:not_mocked, Repo} -> :ok
      end
    end)

    :meck.expect(Repo, :update_all, fn _query, _updates ->
      Agent.get_and_update(calls, fn
        0 -> {{1, nil}, 1}
        1 -> {{nil, nil}, 2}
        count -> {{0, nil}, count + 1}
      end)
    end)

    assert :ok = Media.reset_encoder_orphans()
    assert Agent.get(calls, & &1) == 3
  end
end
