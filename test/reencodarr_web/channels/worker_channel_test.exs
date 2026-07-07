defmodule ReencodarrWeb.WorkerChannelTest do
  use ReencodarrWeb.ChannelCase, async: true

  alias Reencodarr.AbAv1.WorkerSessions
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

    test "rejects unsupported protocol versions" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")

      assert_reply push(socket, "announce", %{
                     "worker_id" => "abav1-dev",
                     "protocol_version" => 99,
                     "version" => "0.10.0",
                     "capabilities" => %{"crf_search" => true}
                   }),
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

      assert_reply push(socket1, "announce", %{
                     "worker_id" => "abav1-dev",
                     "protocol_version" => 1,
                     "version" => "0.10.0",
                     "capabilities" => %{"crf_search" => true}
                   }),
                   :ok,
                   %{accepted: true, protocol_version: 1}

      assert {:ok, socket2} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket2} = subscribe_and_join(socket2, "workers:crf_search")

      assert_reply push(socket2, "announce", %{
                     "worker_id" => "abav1-dev",
                     "protocol_version" => 1,
                     "version" => "0.10.0",
                     "capabilities" => %{"crf_search" => true}
                   }),
                   :error,
                   %{reason: "duplicate_worker_id"}

      Process.unlink(socket1.channel_pid)
      assert :ok = close(socket1)

      assert_reply push(socket2, "announce", %{
                     "worker_id" => "abav1-dev",
                     "protocol_version" => 1,
                     "version" => "0.10.0",
                     "capabilities" => %{"crf_search" => true}
                   }),
                   :ok,
                   %{accepted: true, protocol_version: 1}
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
  end
end
