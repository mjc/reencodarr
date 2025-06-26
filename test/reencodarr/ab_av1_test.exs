defmodule Reencodarr.AbAv1Test do
  use ExUnit.Case, async: true

  alias Reencodarr.AbAv1

  describe "start_link/1" do
    test "starts the supervisor" do
      pid = Process.whereis(Reencodarr.AbAv1)

      case pid do
        nil ->
          assert {:ok, new_pid} = AbAv1.start_link([])
          assert_supervisor_healthy(new_pid)
          Process.exit(new_pid, :normal)

        existing_pid ->
          assert_supervisor_healthy(existing_pid)
      end
    end

    defp assert_supervisor_healthy(pid) do
      assert Process.alive?(pid)
      assert Supervisor.which_children(pid) |> is_list()
    end
  end

  describe "queue_length/0" do
    test "returns queue lengths as integers" do
      result = AbAv1.queue_length()
      assert is_map(result)
      assert Map.has_key?(result, :crf_searches)
      assert Map.has_key?(result, :encodes)
      assert is_integer(result.crf_searches)
      assert is_integer(result.encodes)
    end
  end

  describe "crf_search/2 and encode/1" do
    test "calls GenServer.cast for crf_search and encode" do
      # Patch GenServer.cast to capture calls
      me = self()

      patch = fn mod, msg ->
        send(me, {:cast, mod, msg})
        :ok
      end

      :meck.new(GenServer, [:passthrough])
      :meck.expect(GenServer, :cast, patch)

      video = %{id: 123, path: "foo", size: 100}
      vmaf = %{id: 456, video_id: 123, crf: 28.0, score: 95.0, percent: 95.0}

      AbAv1.crf_search(video, 95)
      assert_receive {:cast, Reencodarr.AbAv1.CrfSearch, {:crf_search, ^video, 95}}

      AbAv1.encode(vmaf)
      assert_receive {:cast, Reencodarr.AbAv1.Encode, {:encode, ^vmaf}}

      :meck.unload()
    end
  end
end
