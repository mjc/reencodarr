defmodule ReencodarrWeb.WorkerChannelTest do
  use ReencodarrWeb.ChannelCase, async: false

  alias Reencodarr.AbAv1.WorkerSessions
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Fixtures
  alias Reencodarr.Media
  alias ReencodarrWeb.WorkerChannel
  alias ReencodarrWeb.WorkerSocket
  import Reencodarr.TestHelpers

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

    test "broadcasts transfer and CRF progress updates" do
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

      assert_reply push(socket, "transfer_progress", %{
                     "video_id" => video_id,
                     "transfer_id" => "transfer-1",
                     "percent" => 25.5,
                     "bytes_sent" => 2_621_440,
                     "total_bytes" => 10_485_760,
                     "chunk_index" => 2,
                     "total_chunks" => 8
                   }),
                   :ok,
                   %{accepted: true, event: "transfer_progress"}

      assert_receive {:transfer_progress,
                      %{
                        video_id: ^video_id,
                        transfer_id: "transfer-1",
                        percent: 25.5,
                        bytes_sent: 2_621_440,
                        total_bytes: 10_485_760
                      }}

      assert_reply push(socket, "crf_search_progress", %{
                     "video_id" => video_id,
                     "percent" => 62.0,
                     "filename" => Path.basename(video.path),
                     "eta" => 90,
                     "fps" => 12.5
                   }),
                   :ok,
                   %{accepted: true, event: "crf_search_progress"}

      assert_receive {:crf_search_progress,
                      %{
                        video_id: ^video_id,
                        percent: 62.0,
                        filename: filename,
                        eta: 90,
                        fps: 12.5
                      }}

      assert filename == Path.basename(video.path)
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "streams assigned media in ordered chunks with integrity data" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      content = :binary.copy("abcd", 262_145)
      content_size = byte_size(content)
      first_chunk = binary_part(content, 0, 1_048_576)
      second_chunk = binary_part(content, 1_048_576, content_size - 1_048_576)
      first_crc32 = :erlang.crc32(first_chunk)
      second_crc32 = :erlang.crc32(second_chunk)
      first_encoded = Base.encode64(first_chunk)
      second_encoded = Base.encode64(second_chunk)

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
                       chunk_size_bytes: 1_048_576
                     }

        assert assigned_video_id == video.id

        assert_push "transfer_started", %{
          status: "transfer_started",
          video_id: ^assigned_video_id,
          transfer_id: transfer_id,
          size_bytes: content_size,
          chunk_size_bytes: 1_048_576,
          total_bytes: content_size,
          total_chunks: 2
        }

        assert_push "transfer_chunk", %{
          status: "transfer_chunk",
          video_id: ^assigned_video_id,
          transfer_id: ^transfer_id,
          chunk_index: 0,
          total_chunks: 2,
          bytes_sent: 1_048_576,
          total_bytes: ^content_size,
          crc32: ^first_crc32,
          data: ^first_encoded
        }

        assert_push "transfer_chunk", %{
          status: "transfer_chunk",
          video_id: ^assigned_video_id,
          transfer_id: ^transfer_id,
          chunk_index: 1,
          total_chunks: 2,
          bytes_sent: ^content_size,
          total_bytes: ^content_size,
          crc32: ^second_crc32,
          data: ^second_encoded
        }

        assert_push "transfer_complete", %{
          status: "transfer_complete",
          video_id: ^assigned_video_id,
          transfer_id: ^transfer_id,
          total_bytes: ^content_size,
          total_chunks: 2
        }
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

      assert_reply push(socket, "crf_search_completed", %{
                     "video_id" => video_id,
                     "result" => "ok",
                     "chosen_crf" => 28
                   }),
                   :ok,
                   %{accepted: true, event: "crf_search_completed"}

      assert_receive {:crf_search_completed, %{video_id: ^video_id, result: :ok, chosen_crf: 28}}

      assert Media.get_video(video_id).state == :crf_searched
      assert Media.get_video(video_id).chosen_vmaf_id != nil
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
