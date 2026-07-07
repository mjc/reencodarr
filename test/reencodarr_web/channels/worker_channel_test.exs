defmodule ReencodarrWeb.WorkerChannelTest do
  use ReencodarrWeb.ChannelCase, async: false

  alias Reencodarr.AbAv1.WorkerSessions
  alias Reencodarr.Fixtures
  alias Reencodarr.Media
  alias ReencodarrWeb.WorkerChannel
  alias ReencodarrWeb.WorkerSocket

  describe "ab-av1 worker websocket" do
    setup do
      WorkerSessions.reset()
      :ok
    end

    test "authenticates, announces capabilities, and returns no work" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      assert socket.assigns.worker_id =~ "worker-"

      assert {:ok, %{worker_id: worker_id}, socket} =
               subscribe_and_join(socket, "workers:crf_search")

      assert worker_id == socket.assigns.worker_id

      assert_reply push(socket, "announce", %{
                     "worker_id" => "abav1-dev",
                     "protocol_version" => 1,
                     "version" => "0.10.0",
                     "capabilities" => %{"crf_search" => true}
                   }),
                   :ok,
                   %{accepted: true, protocol_version: 1}

      assert_reply push(socket, "pull_work", %{}), :ok, %{status: "no_work"}
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "assigns one queued video to a worker and marks it crf_searching" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      {:ok, video} = Fixtures.video_fixture(%{state: :analyzed})

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")

      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-a")),
                   :ok,
                   %{accepted: true, protocol_version: 1}

      assert_reply push(socket, "pull_work", %{}),
                   :ok,
                   %{
                     status: "job_assigned",
                     job_id: job_id,
                     video_id: assigned_video_id,
                     source_name: source_name,
                     size_bytes: size_bytes,
                     chunk_size_bytes: 1_048_576
                   }

      assert job_id == Integer.to_string(video.id)
      assert assigned_video_id == video.id
      assert source_name == Path.basename(video.path)
      assert size_bytes == video.size
      assert Media.get_video(video.id).state == :crf_searching
      assert [session] = WorkerSessions.list()
      assert session.active_video_id == video.id
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "rejects unsupported protocol versions" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")

      assert_reply push(socket, "announce", announce_payload(protocol_version: 99)),
                   :error,
                   %{reason: "unsupported_protocol_version", supported_protocol_versions: [1]}
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "rejects duplicate worker ids until the first session disconnects" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      assert {:ok, socket1} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket1} = subscribe_and_join(socket1, "workers:crf_search")

      assert_reply push(socket1, "announce", announce_payload()),
                   :ok,
                   %{accepted: true, protocol_version: 1}

      assert {:ok, socket2} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket2} = subscribe_and_join(socket2, "workers:crf_search")

      assert_reply push(socket2, "announce", announce_payload()),
                   :error,
                   %{reason: "duplicate_worker_id"}

      Process.unlink(socket1.channel_pid)
      assert :ok = close(socket1)

      assert_reply push(socket2, "announce", announce_payload()),
                   :ok,
                   %{accepted: true, protocol_version: 1}
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "does not hand the same queued video to two workers" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      {:ok, video} = Fixtures.video_fixture(%{state: :analyzed})

      assert {:ok, socket1} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket1} = subscribe_and_join(socket1, "workers:crf_search")

      assert_reply push(socket1, "announce", announce_payload(worker_id: "worker-a")),
                   :ok,
                   %{accepted: true, protocol_version: 1}

      assert {:ok, socket2} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket2} = subscribe_and_join(socket2, "workers:crf_search")

      assert_reply push(socket2, "announce", announce_payload(worker_id: "worker-b")),
                   :ok,
                   %{accepted: true, protocol_version: 1}

      assert_reply push(socket1, "pull_work", %{}),
                   :ok,
                   %{status: "job_assigned", video_id: assigned_video_id}

      assert assigned_video_id == video.id

      assert_reply push(socket2, "pull_work", %{}),
                   :ok,
                   %{status: "no_work"}
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "tracks heartbeat last-seen for announced sessions" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")

      assert_reply push(socket, "announce", announce_payload()), :ok, %{
        accepted: true,
        protocol_version: 1
      }

      [session] = WorkerSessions.list()
      connected_at = session.connected_at
      first_seen_at = session.last_seen_at

      assert_reply push(socket, "heartbeat", %{}), :ok, %{
        accepted: true,
        last_seen_at: last_seen_at
      }

      assert {:ok, parsed_last_seen_at, 0} = DateTime.from_iso8601(last_seen_at)

      [updated_session] = WorkerSessions.list()
      assert updated_session.connected_at == connected_at
      assert DateTime.compare(updated_session.last_seen_at, first_seen_at) in [:eq, :gt]
      assert updated_session.last_seen_at == parsed_last_seen_at
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "requeues active work when the worker disconnects" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      {:ok, video} = Fixtures.video_fixture(%{state: :analyzed})

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")

      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-a")),
                   :ok,
                   %{accepted: true, protocol_version: 1}

      assert_reply push(socket, "pull_work", %{}),
                   :ok,
                   %{status: "job_assigned", video_id: assigned_video_id}

      assert assigned_video_id == video.id
      assert Media.get_video(video.id).state == :crf_searching

      Process.unlink(socket.channel_pid)
      assert :ok = close(socket)

      assert Media.get_video(video.id).state == :analyzed
      assert WorkerSessions.list() == []
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "rejects missing or invalid tokens" do
      Application.put_env(:reencodarr, :worker_token, "test-worker-token")

      assert :error = connect(WorkerSocket, %{})
      assert :error = connect(WorkerSocket, %{"token" => "wrong"})
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "rejects invalid topics without crashing" do
      assert {:error, %{reason: "unauthorized"}} =
               WorkerChannel.join("workers:other", %{}, %{assigns: %{worker_id: "worker-1"}})
    after
      Application.delete_env(:reencodarr, :worker_token)
    end
  end

  defp announce_payload(overrides \\ []) do
    override_map =
      overrides
      |> Enum.into(%{})
      |> Map.new(fn
        {key, value} when is_atom(key) -> {Atom.to_string(key), value}
        pair -> pair
      end)

    Map.merge(
      %{
        "worker_id" => "abav1-dev",
        "protocol_version" => 1,
        "version" => "0.10.0",
        "capabilities" => %{"crf_search" => true}
      },
      override_map
    )
  end
end
