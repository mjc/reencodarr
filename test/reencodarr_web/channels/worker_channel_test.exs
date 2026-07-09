defmodule ReencodarrWeb.WorkerChannelTest do
  use ReencodarrWeb.ChannelCase, async: false

  alias Reencodarr.AbAv1.WorkerProtocol
  alias Reencodarr.AbAv1.WorkerSessions
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Fixtures
  alias Reencodarr.Media
  alias ReencodarrWeb.WorkerChannel
  alias ReencodarrWeb.WorkerSocket
  import Reencodarr.TestHelpers

  describe "ab-av1 worker websocket" do
    setup do
      previous_enabled = Application.get_env(:reencodarr, :distributed_worker_enabled)
      Application.put_env(:reencodarr, :distributed_worker_enabled, true)
      WorkerSessions.reset()

      on_exit(fn ->
        if is_nil(previous_enabled) do
          Application.delete_env(:reencodarr, :distributed_worker_enabled)
        else
          Application.put_env(:reencodarr, :distributed_worker_enabled, previous_enabled)
        end
      end)

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
                     chunk_size_bytes: 134_217_728,
                     crf_search_args: crf_search_args
                   }

      assert job_id == Integer.to_string(video.id)
      assert assigned_video_id == video.id
      assert source_name == Path.basename(video.path)
      assert size_bytes == video.size
      assert "crf-search" in crf_search_args
      assert "--input" in crf_search_args
      assert video.path in crf_search_args
      assert "--min-vmaf" in crf_search_args
      assert "95" in crf_search_args
      assert "--encoder" in crf_search_args
      assert "svt-av1" in crf_search_args
      assert Media.get_video(video.id).state == :crf_searching
      assert Media.get_video(video.id).crf_search_worker_id == "worker-a"
      assert [session] = WorkerSessions.list()
      assert session.active_video_id == video.id
      assert session.phase == :receiving_input
      assert is_nil(session.transfer_progress)
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

    test "replaces reconnecting worker sessions with the same client id" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      assert {:ok, socket1} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket1} = subscribe_and_join(socket1, "workers:crf_search")
      server_worker_id1 = socket1.assigns.worker_id

      assert_reply push(socket1, "announce", announce_payload()),
                   :ok,
                   %{accepted: true, protocol_version: 1}

      assert {:ok, socket2} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket2} = subscribe_and_join(socket2, "workers:crf_search")
      server_worker_id2 = socket2.assigns.worker_id

      assert_reply push(socket2, "announce", announce_payload()),
                   :ok,
                   %{accepted: true, protocol_version: 1}

      assert is_nil(WorkerSessions.get(server_worker_id1))
      assert WorkerSessions.get(server_worker_id2).client_worker_id == "abav1-dev"
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

      assert_reply push(socket, "heartbeat", %{
                     "cpu_percent" => 87.5,
                     "memory_bytes" => 1_073_741_824,
                     "memory_total_bytes" => 4_294_967_296,
                     "disk_free_bytes" => 536_870_912_000,
                     "disk_total_bytes" => 1_099_511_627_776
                   }),
                   :ok,
                   %{
                     accepted: true,
                     last_seen_at: last_seen_at
                   }

      assert {:ok, parsed_last_seen_at, 0} = DateTime.from_iso8601(last_seen_at)

      [updated_session] = WorkerSessions.list()
      assert updated_session.connected_at == connected_at
      assert DateTime.compare(updated_session.last_seen_at, first_seen_at) in [:eq, :gt]
      assert updated_session.last_seen_at == parsed_last_seen_at
      assert updated_session.resource_usage.cpu_percent == 87.5
      assert updated_session.resource_usage.memory_bytes == 1_073_741_824
      assert updated_session.resource_usage.memory_total_bytes == 4_294_967_296
      assert updated_session.resource_usage.disk_free_bytes == 536_870_912_000
      assert updated_session.resource_usage.disk_total_bytes == 1_099_511_627_776
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "tracks last-seen for pull_work requests on active sessions" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      {:ok, video} = Fixtures.video_fixture(%{state: :analyzed})
      video_id = video.id

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")

      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-a")), :ok, %{
        accepted: true
      }

      assert_reply push(socket, "pull_work", %{}), :ok, %{
        status: "job_assigned",
        video_id: ^video_id
      }

      [session] = WorkerSessions.list()
      first_seen_at = session.last_seen_at

      Process.sleep(1_100)

      assert_reply push(socket, "pull_work", %{}), :ok, %{status: status, video_id: ^video_id}
      assert status in ["job_assigned", "job_in_progress"]

      [updated_session] = WorkerSessions.list()
      assert DateTime.compare(updated_session.last_seen_at, first_seen_at) == :gt
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "broadcasts transfer and CRF progress updates" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())

      {:ok, video} = Fixtures.video_fixture(%{state: :analyzed})
      video_id = video.id

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")
      server_worker_id = socket.assigns.worker_id

      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-a")),
                   :ok,
                   %{accepted: true, protocol_version: 1}

      assert_reply push(socket, "pull_work", %{}),
                   :ok,
                   %{status: "job_assigned", video_id: ^video_id}

      assert_reply push(socket, "transfer_progress", %{
                     "video_id" => video_id,
                     "job_id" => "job-1",
                     "filename" => Path.basename(video.path),
                     "percent" => 25.5,
                     "received_bytes" => 2_621_440,
                     "expected_bytes" => 10_485_760,
                     "bytes_per_second" => 1_048_576,
                     "eta" => 15,
                     "chunk_index" => 2,
                     "total_chunks" => 8
                   }),
                   :ok,
                   %{accepted: true, event: "transfer_progress"}

      assert_receive {:transfer_progress,
                      %{
                        video_id: ^video_id,
                        transfer_id: "job-1",
                        job_id: "job-1",
                        filename: filename,
                        percent: 25.5,
                        bytes_sent: 2_621_440,
                        total_bytes: 10_485_760,
                        bytes_per_second: 1_048_576,
                        eta: 15,
                        chunk_index: 2,
                        total_chunks: 8
                      }}

      assert filename == Path.basename(video.path)

      Process.sleep(10)

      assert_reply push(socket, "transfer_progress", %{
                     "video_id" => video_id,
                     "job_id" => "job-1",
                     "filename" => Path.basename(video.path),
                     "percent" => 50.0,
                     "received_bytes" => 5_242_880,
                     "expected_bytes" => 10_485_760,
                     "chunk_index" => 3,
                     "total_chunks" => 8
                   }),
                   :ok,
                   %{accepted: true, event: "transfer_progress"}

      assert_receive {:transfer_progress,
                      %{
                        video_id: ^video_id,
                        bytes_sent: 5_242_880,
                        total_bytes: 10_485_760,
                        bytes_per_second: derived_rate,
                        eta: derived_eta
                      }}

      assert is_integer(derived_rate)
      assert derived_rate > 0
      assert is_integer(derived_eta)
      assert derived_eta >= 0

      assert_reply push(socket, "crf_search_progress", %{
                     "video_id" => video_id,
                     "percent" => 62.0,
                     "filename" => Path.basename(video.path),
                     "eta" => 90,
                     "fps" => 12.5,
                     "crf" => 28.0,
                     "sample_num" => 3,
                     "total_samples" => 8
                   }),
                   :ok,
                   %{accepted: true, event: "crf_search_progress"}

      assert_receive {:crf_search_progress,
                      %{
                        video_id: ^video_id,
                        percent: 62.0,
                        filename: filename,
                        eta: 90,
                        fps: 12.5,
                        crf: 28.0,
                        sample_num: 3,
                        total_samples: 8
                      }}

      assert filename == Path.basename(video.path)
      session = WorkerSessions.get(server_worker_id)
      assert session.phase == :crf_searching
      assert is_nil(session.transfer_progress)
      assert session.crf_search_progress.percent == 62.0

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        WorkerChannel.worker_control_topic(server_worker_id),
        {:worker_control, :pause}
      )

      assert_push "control", %{action: "pause", video_id: ^video_id}
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "accepts resumed CRF progress for already-searching video after reconnect" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      {:ok, video} =
        Fixtures.video_fixture(%{state: :crf_searching, crf_search_worker_id: "worker-a"})

      video_id = video.id

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")
      server_worker_id = socket.assigns.worker_id

      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-a")),
                   :ok,
                   %{accepted: true, protocol_version: 1}

      session = WorkerSessions.get(server_worker_id)
      assert is_nil(session.active_video_id)

      assert_reply push(socket, "crf_search_progress", %{
                     "video_id" => video_id,
                     "percent" => 16.4,
                     "filename" => Path.basename(video.path),
                     "fps" => 24.0,
                     "crf" => 28.0,
                     "sample_num" => 2,
                     "total_samples" => 8
                   }),
                   :ok,
                   %{accepted: true, event: "crf_search_progress"}

      session = WorkerSessions.get(server_worker_id)
      assert session.active_video_id == video_id
      assert session.crf_search_progress.sample_num == 2
      assert Media.get_video(video_id).state == :crf_searching
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "does not restart transfer when reconnected worker asks for work already in progress" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      {:ok, video} =
        Fixtures.video_fixture(%{state: :crf_searching, crf_search_worker_id: "worker-a"})

      video_id = video.id

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")
      server_worker_id = socket.assigns.worker_id

      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-a")),
                   :ok,
                   %{accepted: true, protocol_version: 1}

      assert_reply push(socket, "crf_search_progress", %{
                     "video_id" => video_id,
                     "percent" => 12.5,
                     "filename" => Path.basename(video.path),
                     "fps" => 24.0,
                     "crf" => 28.0,
                     "sample_num" => 1,
                     "total_samples" => 8
                   }),
                   :ok,
                   %{accepted: true, event: "crf_search_progress"}

      assert {:error, :invalid_worker_phase} =
               WorkerSessions.set_transfer_progress(server_worker_id, %{
                 job_id: Integer.to_string(video_id),
                 video_id: video_id,
                 transfer_id: Integer.to_string(video_id),
                 filename: Path.basename(video.path),
                 percent: 100.0,
                 bytes_sent: 8,
                 total_bytes: 8
               })

      assert_reply push(socket, "pull_work", %{}),
                   :ok,
                   %{
                     status: "job_in_progress",
                     video_id: ^video_id,
                     target_vmaf: 95,
                     crf_search_args: crf_search_args
                   }

      assert "crf-search" in crf_search_args
      assert "--input" in crf_search_args
      assert video.path in crf_search_args
      assert "--min-vmaf" in crf_search_args
      assert "95" in crf_search_args

      refute_push "transfer_started", _, 50
      refute_push "transfer_chunk", _, 50

      session = WorkerSessions.get(server_worker_id)
      assert session.active_video_id == video_id
      assert Media.get_video(video_id).state == :crf_searching
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "reattaches dispatched work when reconnecting worker asks for work" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      with_temp_file("abcdefgh", ".mkv", fn path ->
        {:ok, video} =
          Fixtures.video_fixture(%{
            path: path,
            size: 8,
            state: :crf_searching,
            crf_search_worker_id: "worker-a"
          })

        video_id = video.id

        assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
        assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")

        assert_reply push(socket, "announce", announce_payload(worker_id: "worker-a")),
                     :ok,
                     %{accepted: true, protocol_version: 1}

        assert_reply push(socket, "pull_work", %{}),
                     :ok,
                     %{status: "job_in_progress", video_id: ^video_id}

        assert Media.get_video(video_id).state == :crf_searching
        assert Media.get_video_failures(video_id) == []
        assert WorkerSessions.get(socket.assigns.worker_id).phase == :crf_searching
        refute_push "transfer_started", _, 50
      end)
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "resends dispatched work when reconnecting worker reports missing input" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      with_temp_file("abcdefgh", ".mkv", fn path ->
        {:ok, video} =
          Fixtures.video_fixture(%{
            path: path,
            size: 8,
            state: :crf_searching,
            crf_search_worker_id: "worker-a"
          })

        video_id = video.id

        assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
        assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")

        assert_reply push(socket, "announce", announce_payload(worker_id: "worker-a")),
                     :ok,
                     %{accepted: true, protocol_version: 1}

        assert_reply push(socket, "pull_work", %{"input_missing" => true}),
                     :ok,
                     %{
                       status: "job_assigned",
                       video_id: ^video_id,
                       crf_search_args: crf_search_args
                     }

        assert "crf-search" in crf_search_args
        assert_push "transfer_started", %{status: "transfer_started", video_id: ^video_id}
      end)
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "returns in-progress work when an assigned worker asks again" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      {:ok, video} = Fixtures.video_fixture(%{state: :analyzed})
      video_id = video.id

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")

      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-a")),
                   :ok,
                   %{accepted: true, protocol_version: 1}

      assert_reply push(socket, "pull_work", %{}),
                   :ok,
                   %{status: "job_assigned", video_id: ^video_id, crf_search_args: assigned_args}

      assert_reply push(socket, "crf_search_progress", %{
                     "video_id" => video_id,
                     "percent" => 12.5,
                     "filename" => Path.basename(video.path),
                     "fps" => 24.0,
                     "crf" => 28.0,
                     "sample_num" => 1,
                     "total_samples" => 8
                   }),
                   :ok,
                   %{accepted: true, event: "crf_search_progress"}

      assert_reply push(socket, "pull_work", %{}),
                   :ok,
                   %{
                     status: "job_in_progress",
                     video_id: ^video_id,
                     crf_search_args: in_progress_args
                   }

      assert assigned_args == in_progress_args
      assert video.path in in_progress_args
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "resends the input when a reconnecting worker still has transfer progress" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      with_temp_file("abcdefgh", ".mkv", fn path ->
        {:ok, video} =
          Fixtures.video_fixture(%{
            state: :analyzed,
            path: path,
            size: 8
          })

        video_id = video.id

        assert {:ok, _session} =
                 WorkerSessions.register(%{
                   server_worker_id: "worker-server-1",
                   client_worker_id: "worker-a",
                   protocol_version: 1,
                   version: "0.10.0",
                   capabilities: %{"crf_search" => true}
                 })

        assert {:ok, _session} =
                 WorkerSessions.assign_video("worker-server-1", video_id, :receiving_input)

        assert {:ok, _session} =
                 WorkerSessions.set_transfer_progress("worker-server-1", %{
                   job_id: Integer.to_string(video_id),
                   transfer_id: Integer.to_string(video_id),
                   filename: Path.basename(video.path),
                   percent: 50.0,
                   bytes_sent: 4,
                   total_bytes: 8,
                   bytes_per_second: 256,
                   eta: 2,
                   chunk_index: 1,
                   total_chunks: 2
                 })

        assert {:ok, socket2} = connect(WorkerSocket, %{"token" => token})
        assert {:ok, _join_payload, socket2} = subscribe_and_join(socket2, "workers:crf_search")

        assert_reply push(socket2, "announce", announce_payload(worker_id: "worker-a")),
                     :ok,
                     %{accepted: true, protocol_version: 1}

        assert_reply push(socket2, "pull_work", %{}),
                     :ok,
                     %{
                       status: "job_assigned",
                       video_id: ^video_id,
                       chunk_size_bytes: chunk_size_bytes
                     }

        assert_push "transfer_started", %{
          status: "transfer_started",
          video_id: ^video_id,
          transfer_id: transfer_id,
          chunk_size_bytes: ^chunk_size_bytes
        }

        assert transfer_id == Integer.to_string(video_id)
      end)
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "reattaches dispatched work when the session state is gone" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      with_temp_file("abcdefgh", ".mkv", fn path ->
        {:ok, video} =
          Fixtures.video_fixture(%{
            path: path,
            size: 8,
            state: :crf_searching,
            crf_search_worker_id: "worker-dispatch-gone"
          })

        video_id = video.id

        assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
        assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")

        assert_reply push(
                       socket,
                       "announce",
                       announce_payload(worker_id: "worker-dispatch-gone")
                     ),
                     :ok,
                     %{accepted: true, protocol_version: 1}

        assert_reply push(socket, "pull_work", %{}),
                     :ok,
                     %{status: "job_in_progress", video_id: ^video_id}

        assert Media.get_video(video_id).state == :crf_searching
        assert WorkerSessions.get(socket.assigns.worker_id).phase == :crf_searching
        refute_push "transfer_started", _, 50
      end)
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "streams assigned media in ordered chunks with integrity data" do
      token = "test-worker-token"
      previous_chunk_size = Application.get_env(:reencodarr, :worker_chunk_size_bytes)
      Application.put_env(:reencodarr, :worker_token, token)
      Application.put_env(:reencodarr, :worker_chunk_size_bytes, 4)

      on_exit(fn ->
        if is_nil(previous_chunk_size) do
          Application.delete_env(:reencodarr, :worker_chunk_size_bytes)
        else
          Application.put_env(:reencodarr, :worker_chunk_size_bytes, previous_chunk_size)
        end
      end)

      chunk_size = 4
      content = "abcdefgh"
      content_size = byte_size(content)
      first_chunk = binary_part(content, 0, chunk_size)
      second_chunk = binary_part(content, chunk_size, content_size - chunk_size)
      first_crc32 = :erlang.crc32(first_chunk)
      second_crc32 = :erlang.crc32(second_chunk)

      with_temp_file(content, ".mkv", fn path ->
        {:ok, video} =
          Fixtures.video_fixture(%{
            path: path,
            size: content_size,
            state: :analyzed
          })

        assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
        assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")

        assert_reply push(socket, "announce", announce_payload(worker_id: "worker-a")),
                     :ok,
                     %{accepted: true, protocol_version: 1}

        assert_reply push(socket, "pull_work", %{}),
                     :ok,
                     %{
                       status: "job_assigned",
                       video_id: assigned_video_id,
                       chunk_size_bytes: ^chunk_size
                     }

        assert assigned_video_id == video.id

        assert_push "transfer_started", %{
          status: "transfer_started",
          video_id: ^assigned_video_id,
          transfer_id: transfer_id,
          size_bytes: content_size,
          chunk_size_bytes: ^chunk_size,
          total_bytes: content_size,
          total_chunks: 2
        }

        session = WorkerSessions.get(socket.assigns.worker_id)
        assert session.active_video_id == assigned_video_id
        assert session.phase == :receiving_input
        assert session.transfer_progress.video_id == assigned_video_id
        assert session.transfer_progress.percent == 0.0
        assert session.transfer_progress.bytes_sent == 0
        assert session.transfer_progress.total_bytes == content_size
        assert session.transfer_progress.chunk_index == 0
        assert session.transfer_progress.total_chunks == 2

        assert_push "transfer_chunk", {:binary, first_frame}

        assert {:ok,
                %{
                  video_id: ^assigned_video_id,
                  transfer_id: ^transfer_id,
                  chunk_index: 0,
                  total_chunks: 2,
                  bytes_sent: ^chunk_size,
                  total_bytes: ^content_size,
                  crc32: ^first_crc32,
                  data: ^first_chunk
                }} = WorkerProtocol.parse_transfer_chunk_frame(first_frame)

        refute_push "transfer_chunk", _, 50

        assert_reply push(socket, "transfer_progress", %{
                       "job_id" => transfer_id,
                       "transfer_id" => transfer_id,
                       "video_id" => assigned_video_id,
                       "percent" => 50.0,
                       "received_bytes" => chunk_size,
                       "expected_bytes" => content_size,
                       "chunk_index" => 0,
                       "total_chunks" => 2
                     }),
                     :ok,
                     %{accepted: true, event: "transfer_progress"}

        assert_push "transfer_chunk", {:binary, second_frame}

        assert {:ok,
                %{
                  video_id: ^assigned_video_id,
                  transfer_id: ^transfer_id,
                  chunk_index: 1,
                  total_chunks: 2,
                  bytes_sent: ^content_size,
                  total_bytes: ^content_size,
                  crc32: ^second_crc32,
                  data: ^second_chunk
                }} = WorkerProtocol.parse_transfer_chunk_frame(second_frame)

        refute_push "transfer_complete", _, 50

        assert_reply push(socket, "transfer_progress", %{
                       "job_id" => transfer_id,
                       "transfer_id" => transfer_id,
                       "video_id" => assigned_video_id,
                       "percent" => 100.0,
                       "received_bytes" => content_size,
                       "expected_bytes" => content_size,
                       "chunk_index" => 1,
                       "total_chunks" => 2
                     }),
                     :ok,
                     %{accepted: true, event: "transfer_progress"}

        session = WorkerSessions.get(socket.assigns.worker_id)
        assert session.active_video_id == assigned_video_id
        assert session.phase == :input_ready
        assert session.transfer_progress.video_id == assigned_video_id
        assert session.transfer_progress.bytes_sent == content_size
        assert session.transfer_progress.total_bytes == content_size
        assert session.transfer_progress.chunk_index == 1
        assert session.transfer_progress.total_chunks == 2
        assert session.transfer_progress.percent == 100.0

        assert_push "transfer_complete", %{
          status: "transfer_complete",
          video_id: ^assigned_video_id,
          transfer_id: ^transfer_id,
          total_bytes: ^content_size,
          total_chunks: 2
        }

        session = WorkerSessions.get(socket.assigns.worker_id)
        assert session.active_video_id == assigned_video_id
        assert session.phase == :input_ready
        assert session.transfer_progress.video_id == assigned_video_id
      end)
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "submits structured CRF results and completes the job" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())

      {:ok, video} = Fixtures.video_fixture(%{state: :analyzed})
      video_id = video.id

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")

      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-a")),
                   :ok,
                   %{accepted: true, protocol_version: 1}

      assert_reply push(socket, "pull_work", %{}),
                   :ok,
                   %{status: "job_assigned", video_id: ^video_id}

      assert_reply push(socket, "crf_search_result", %{
                     "video_id" => video_id,
                     "results" => [
                       %{
                         "crf" => 26,
                         "score" => 94.1,
                         "percent" => 93.0,
                         "size" => "600 MB",
                         "params" => ["--preset", "4"]
                       },
                       %{
                         "crf" => 28,
                         "score" => 96.4,
                         "percent" => 95.0,
                         "size" => "520 MB",
                         "params" => ["--preset", "4"],
                         "chosen" => true
                       }
                     ]
                   }),
                   :ok,
                   %{accepted: true, event: "crf_search_result"}

      assert_receive {:crf_search_vmaf_result, %{video_id: ^video_id, crf: 26.0, score: 94.1}}
      assert_receive {:crf_search_vmaf_result, %{video_id: ^video_id, crf: 28.0, score: 96.4}}

      vmafs = Media.get_vmafs_for_video(video_id)
      assert Enum.any?(vmafs, &(&1.crf == 26.0 and &1.score == 94.1))
      assert Enum.any?(vmafs, &(&1.crf == 28.0 and &1.score == 96.4))
      assert WorkerSessions.get(socket.assigns.worker_id).active_video_id == nil

      assert_reply push(socket, "crf_search_completed", %{
                     "video_id" => video_id,
                     "result" => "ok",
                     "chosen_crf" => 28
                   }),
                   :ok,
                   %{accepted: true, event: "crf_search_completed"}

      assert Media.get_video(video_id).state == :crf_searched
      assert Media.get_video(video_id).chosen_vmaf_id != nil
      assert WorkerSessions.get(socket.assigns.worker_id).active_video_id == nil

      assert_reply push(socket, "pull_work", %{}),
                   :ok,
                   %{status: "no_work"}

      assert_reply push(socket, "crf_search_result", %{
                     "video_id" => video_id,
                     "results" => [
                       %{
                         "crf" => 28,
                         "score" => 96.4,
                         "percent" => 95.0,
                         "chosen" => true
                       }
                     ]
                   }),
                   :ok,
                   %{accepted: true, event: "crf_search_result"}

      assert WorkerSessions.get(socket.assigns.worker_id).active_video_id == nil
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "clears stale active work when a worker asks after the video completed elsewhere" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      {:ok, video} = Fixtures.video_fixture(%{state: :analyzed})
      video_id = video.id

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")

      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-a")),
                   :ok,
                   %{accepted: true, protocol_version: 1}

      assert_reply push(socket, "pull_work", %{}),
                   :ok,
                   %{status: "job_assigned", video_id: ^video_id}

      _vmaf = Fixtures.vmaf_fixture(%{video_id: video_id, crf: 28.0, score: 96.4})
      assert {:ok, _} = Media.mark_vmaf_as_chosen(video_id, 28.0)
      assert {:ok, _} = Media.mark_as_crf_searched(Media.get_video(video_id))

      assert_reply push(socket, "pull_work", %{}),
                   :ok,
                   %{status: "no_work"}

      assert WorkerSessions.get(socket.assigns.worker_id).active_video_id == nil
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "uses an already chosen VMAF when completion omits chosen_crf" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())

      {:ok, video} = Fixtures.video_fixture(%{state: :analyzed})
      video_id = video.id

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")

      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-a")),
                   :ok,
                   %{accepted: true, protocol_version: 1}

      assert_reply push(socket, "pull_work", %{}),
                   :ok,
                   %{status: "job_assigned", video_id: ^video_id}

      assert_reply push(socket, "crf_search_result", %{
                     "video_id" => video_id,
                     "results" => [
                       %{
                         "crf" => 24,
                         "score" => 94.2,
                         "percent" => 90.0,
                         "chosen" => true
                       }
                     ]
                   }),
                   :ok,
                   %{accepted: true, event: "crf_search_result"}

      assert_reply push(socket, "crf_search_completed", %{
                     "video_id" => video_id,
                     "result" => "ok"
                   }),
                   :ok,
                   %{accepted: true, event: "crf_search_completed"}

      assert Media.get_video(video_id).state == :crf_searched
      assert Media.get_video(video_id).chosen_vmaf_id != nil
      assert WorkerSessions.get(socket.assigns.worker_id).active_video_id == nil
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "persists completion VMAF results before completing the job" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())

      {:ok, video} = Fixtures.video_fixture(%{state: :analyzed})
      video_id = video.id

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")

      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-a")),
                   :ok,
                   %{accepted: true, protocol_version: 1}

      assert_reply push(socket, "pull_work", %{}),
                   :ok,
                   %{status: "job_assigned", video_id: ^video_id}

      assert_reply push(socket, "crf_search_completed", %{
                     "video_id" => video_id,
                     "result" => "ok",
                     "results" => [
                       %{
                         "crf" => 13,
                         "vmaf_score" => 90.74086,
                         "encode_percent" => 108.0,
                         "predicted_encode_size" => 5_230_000_000,
                         "predicted_encode_time_secs" => 5160
                       },
                       %{
                         "crf" => 12,
                         "vmaf_score" => 94.86,
                         "encode_percent" => 8.0,
                         "predicted_encode_size" => 263_590_000,
                         "predicted_encode_time_secs" => 1260,
                         "chosen" => true
                       }
                     ]
                   }),
                   :ok,
                   %{accepted: true, event: "crf_search_completed"}

      assert_receive {:crf_search_vmaf_result, %{video_id: ^video_id, crf: 13.0, score: 90.74086}}
      assert_receive {:crf_search_vmaf_result, %{video_id: ^video_id, crf: 12.0, score: 94.86}}

      vmafs = Media.get_vmafs_for_video(video_id)
      assert Enum.any?(vmafs, &(&1.crf == 13.0 and &1.score == 90.74086))
      assert Enum.any?(vmafs, &(&1.crf == 12.0 and &1.score == 94.86))

      video = Media.get_video(video_id)
      assert video.state == :crf_searched
      assert video.chosen_vmaf_id != nil
      assert WorkerSessions.get(socket.assigns.worker_id).active_video_id == nil
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "fails a completed CRF search when nothing was chosen" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      {:ok, video} = Fixtures.video_fixture(%{state: :analyzed})
      video_id = video.id

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")

      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-a")),
                   :ok,
                   %{accepted: true, protocol_version: 1}

      assert_reply push(socket, "pull_work", %{}),
                   :ok,
                   %{status: "job_assigned", video_id: ^video_id}

      assert_reply push(socket, "crf_search_result", %{
                     "video_id" => video_id,
                     "results" => [
                       %{
                         "crf" => 24,
                         "score" => 94.2,
                         "percent" => 90.0
                       }
                     ]
                   }),
                   :ok,
                   %{accepted: true, event: "crf_search_result"}

      assert_reply push(socket, "crf_search_completed", %{
                     "video_id" => video_id,
                     "result" => "ok"
                   }),
                   :error,
                   %{reason: "invalid_crf_search_result"}

      assert Media.get_video(video_id).state == :failed
      assert is_nil(Media.get_video(video_id).chosen_vmaf_id)

      assert_reply push(socket, "pull_work", %{}),
                   :ok,
                   %{status: "no_work"}
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "accepts a CRF result for already dispatched work before the session is rebuilt" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())

      {:ok, video} =
        Fixtures.video_fixture(%{
          state: :crf_searching,
          crf_search_worker_id: "worker-a",
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      video_id = video.id

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")

      assert_reply push(socket, "crf_search_result", %{
                     "job_id" => Integer.to_string(video_id),
                     "video_id" => video_id,
                     "source_name" => Path.basename(video.path),
                     "crf" => 31.0,
                     "vmaf_score" => 96.2,
                     "predicted_encode_size" => 123_456,
                     "encode_percent" => 42.5,
                     "predicted_encode_time_secs" => 87.5,
                     "from_cache" => false
                   }),
                   :ok,
                   %{accepted: true, event: "crf_search_result"}

      assert_receive {:crf_search_vmaf_result, %{video_id: ^video_id, crf: 31.0, score: 96.2}}

      assert Enum.any?(
               Media.get_vmafs_for_video(video_id),
               &(&1.crf == 31.0 and &1.score == 96.2)
             )
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "records typed failures and cancels active work" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())

      {:ok, video} = Fixtures.video_fixture(%{state: :analyzed})
      video_id = video.id

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")

      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-a")),
                   :ok,
                   %{accepted: true, protocol_version: 1}

      assert_reply push(socket, "pull_work", %{}),
                   :ok,
                   %{status: "job_assigned", video_id: ^video_id}

      assert_reply push(socket, "video_failed", %{
                     "video_id" => video_id,
                     "stage" => "crf_search",
                     "category" => "timeout",
                     "message" => "timed out",
                     "code" => "EXIT_137",
                     "context" => %{"node" => "worker@host"},
                     "retriable" => true,
                     "stderr_excerpt" => "ab-av1 timed out"
                   }),
                   :ok,
                   %{accepted: true, event: "video_failed"}

      assert_receive {:video_failed,
                      %{
                        video_id: ^video_id,
                        stage: :crf_search,
                        category: :timeout,
                        message: "timed out"
                      }}

      assert Media.get_video(video_id).state == :failed
      assert [_failure] = Media.get_video_failures(video_id)

      {:ok, cancelled_video} = Fixtures.video_fixture(%{state: :analyzed})
      cancelled_video_id = cancelled_video.id

      assert {:ok, cancel_socket} = connect(WorkerSocket, %{"token" => token})

      assert {:ok, _join_payload, cancel_socket} =
               subscribe_and_join(cancel_socket, "workers:crf_search")

      assert_reply push(cancel_socket, "announce", announce_payload(worker_id: "worker-b")),
                   :ok,
                   %{accepted: true, protocol_version: 1}

      assert_reply push(cancel_socket, "pull_work", %{}),
                   :ok,
                   %{status: "job_assigned", video_id: ^cancelled_video_id}

      assert_reply push(cancel_socket, "crf_search_completed", %{
                     "video_id" => cancelled_video_id,
                     "result" => "cancelled"
                   }),
                   :ok,
                   %{accepted: true, event: "crf_search_completed"}

      assert_receive {:crf_search_completed, %{video_id: ^cancelled_video_id, result: :cancelled}}

      assert Media.get_video(cancelled_video_id).state == :analyzed
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "keeps worker-dispatched active work when the worker disconnects" do
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

      refreshed = Media.get_video(video.id)
      assert refreshed.state == :crf_searching
      assert refreshed.crf_search_worker_id == "worker-a"
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

    test "rejects worker connections when distributed workers are disabled" do
      previous_enabled = Application.get_env(:reencodarr, :distributed_worker_enabled)
      previous_token = Application.get_env(:reencodarr, :worker_token)

      on_exit(fn ->
        if is_nil(previous_enabled) do
          Application.delete_env(:reencodarr, :distributed_worker_enabled)
        else
          Application.put_env(:reencodarr, :distributed_worker_enabled, previous_enabled)
        end

        if is_nil(previous_token) do
          Application.delete_env(:reencodarr, :worker_token)
        else
          Application.put_env(:reencodarr, :worker_token, previous_token)
        end
      end)

      Application.put_env(:reencodarr, :distributed_worker_enabled, false)
      Application.put_env(:reencodarr, :worker_token, "test-worker-token")

      assert :error = connect(WorkerSocket, %{"token" => "test-worker-token"})
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
