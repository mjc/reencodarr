defmodule ReencodarrWeb.WorkerChannelTest do
  use ReencodarrWeb.ChannelCase, async: false

  alias Reencodarr.AbAv1.Encode
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

      assert "crf-" <> _ = job_id
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
      assert Media.get_video(video.id).worker_attempt_id == job_id
      assert Media.get_video(video.id).worker_control_desired_state == :running
      assert Media.get_video(video.id).worker_control_acknowledged_state == :running
      assert [session] = WorkerSessions.list()
      assert session.active_video_id == video.id
      assert session.phase == :receiving_input
      assert is_nil(session.transfer_progress)
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "worker CRF assignment uses the legacy hint range" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      {:ok, video} = Fixtures.video_fixture(%{state: :analyzed})
      Fixtures.vmaf_fixture(%{video_id: video.id, crf: 30.0, score: 96.0})
      Fixtures.vmaf_fixture(%{video_id: video.id, crf: 34.0, score: 94.0})

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")
      assert_reply push(socket, "announce", announce_payload(worker_id: "hint-worker")), :ok

      assert_reply push(socket, "pull_work", %{"job_type" => "crf_search"}),
                   :ok,
                   %{crf_search_args: args}

      assert Enum.at(args, Enum.find_index(args, &(&1 == "--min-crf")) + 1) == "28"
      assert Enum.at(args, Enum.find_index(args, &(&1 == "--max-crf")) + 1) == "36"
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "worker CRF failure retries a hinted search over the full range" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      {:ok, video} = Fixtures.video_fixture(%{state: :analyzed})
      Fixtures.vmaf_fixture(%{video_id: video.id, crf: 30.0, score: 96.0})
      Fixtures.vmaf_fixture(%{video_id: video.id, crf: 34.0, score: 94.0})

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")
      assert_reply push(socket, "announce", announce_payload(worker_id: "retry-worker")), :ok

      assert_reply push(socket, "pull_work", %{"job_type" => "crf_search"}),
                   :ok,
                   %{job_id: job_id, crf_search_args: args}

      assert_reply push(socket, "video_failed", %{
                     "job_id" => job_id,
                     "video_id" => video.id,
                     "stage" => "crf_search",
                     "category" => "crf_optimization",
                     "message" => "no acceptable CRF",
                     "code" => "EXIT_1",
                     "context" => %{"argv" => args}
                   }),
                   :ok,
                   %{accepted: true, event: "video_failed"}

      assert Media.get_video(video.id).state == :analyzed

      assert_reply push(socket, "pull_work", %{"job_type" => "crf_search"}),
                   :ok,
                   %{job_id: retry_job_id, crf_search_args: retry_args}

      refute retry_job_id == job_id
      assert Enum.at(retry_args, Enum.find_index(retry_args, &(&1 == "--min-crf")) + 1) == "5"
      assert Enum.at(retry_args, Enum.find_index(retry_args, &(&1 == "--max-crf")) + 1) == "70"

      assert_reply push(socket, "video_failed", %{
                     "job_id" => retry_job_id,
                     "video_id" => video.id,
                     "stage" => "crf_search",
                     "category" => "crf_optimization",
                     "message" => "no acceptable CRF",
                     "code" => "EXIT_1",
                     "context" => %{"argv" => retry_args}
                   }),
                   :ok,
                   %{accepted: true, event: "video_failed"}

      assert_reply push(socket, "pull_work", %{"job_type" => "crf_search"}),
                   :ok,
                   %{crf_search_args: lower_target_args}

      assert Enum.at(
               lower_target_args,
               Enum.find_index(lower_target_args, &(&1 == "--min-vmaf")) + 1
             ) == "94"
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "reconciles current active attempts and discards stale ones" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      {:ok, video} = Fixtures.video_fixture(%{state: :analyzed})
      {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      {:ok, _, socket} = subscribe_and_join(socket, "workers:crf_search")
      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-a")), :ok
      assert_reply push(socket, "pull_work", %{}), :ok, %{job_id: job_id}

      assert_reply push(socket, "job_active", %{
                     "job_id" => job_id,
                     "video_id" => video.id,
                     "job_type" => "crf_search"
                   }),
                   :ok,
                   %{accepted: true, event: "job_active"}

      assert %{^job_id => %{job_type: :crf_search, active: true}} =
               WorkerSessions.get(socket.assigns.worker_id).jobs

      assert_reply push(socket, "job_active", %{
                     "job_id" => "crf-stale",
                     "video_id" => video.id,
                     "job_type" => "crf_search"
                   }),
                   :ok,
                   %{
                     accepted: false,
                     discarded: true,
                     event: "job_active",
                     reason: "stale_worker_attempt"
                   }
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "restores an active encode reported after server state is lost" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      {:ok, video} = Fixtures.video_fixture(%{state: :crf_searched})
      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id, params: []})
      video = Fixtures.choose_vmaf(video, vmaf)
      job_id = "encode-active-after-restart"

      {:ok, video} =
        Media.mark_as_encoding(video, %{
          encode_worker_id: "worker-restart",
          worker_attempt_id: job_id
        })

      {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      {:ok, _, socket} = subscribe_and_join(socket, "workers:crf_search")
      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-restart")), :ok

      assert_reply push(socket, "job_active", %{
                     "job_id" => job_id,
                     "video_id" => video.id,
                     "job_type" => "encode"
                   }),
                   :ok,
                   %{accepted: true, event: "job_active"}

      assert %{^job_id => %{job_type: :encode, phase: :encoding, active: true}} =
               WorkerSessions.get(socket.assigns.worker_id).jobs
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "rejects CRF progress from a superseded attempt" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      {:ok, video} = Fixtures.video_fixture(%{state: :analyzed})

      {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      {:ok, _, socket} = subscribe_and_join(socket, "workers:crf_search")
      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-crf")), :ok

      assert_reply push(socket, "pull_work", %{}), :ok, %{job_id: job_id}

      assert_reply push(socket, "crf_search_progress", %{
                     "job_id" => "crf-stale",
                     "video_id" => video.id,
                     "percent" => 25.0
                   }),
                   :error,
                   %{reason: "unknown_worker_session"}

      assert %{
               state: :crf_searching,
               crf_search_worker_id: "worker-crf",
               worker_attempt_id: ^job_id
             } = Media.get_video(video.id)
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "rejects transfer progress from a superseded attempt" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      {:ok, video} = Fixtures.video_fixture(%{state: :analyzed})

      {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      {:ok, _, socket} = subscribe_and_join(socket, "workers:crf_search")
      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-crf")), :ok
      assert_reply push(socket, "pull_work", %{}), :ok, %{job_id: job_id}

      assert_reply push(socket, "transfer_progress", %{
                     "job_id" => "crf-stale",
                     "video_id" => video.id,
                     "percent" => 50.0,
                     "received_bytes" => 5,
                     "expected_bytes" => 10
                   }),
                   :error,
                   %{reason: "unknown_worker_session"}

      assert %{^job_id => _job} = WorkerSessions.get(socket.assigns.worker_id).jobs
      refute Map.has_key?(WorkerSessions.get(socket.assigns.worker_id).jobs, "crf-stale")
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "recovers only the persisted CRF attempt after server state is lost" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      {:ok, video} = Fixtures.video_fixture(%{state: :analyzed})

      {:ok, socket1} = connect(WorkerSocket, %{"token" => token})
      {:ok, _, socket1} = subscribe_and_join(socket1, "workers:crf_search")
      assert_reply push(socket1, "announce", announce_payload(worker_id: "worker-crf")), :ok
      assert_reply push(socket1, "pull_work", %{}), :ok, %{job_id: job_id}

      Process.unlink(socket1.channel_pid)
      assert :ok = close(socket1)
      :ok = WorkerSessions.reset()

      {:ok, socket2} = connect(WorkerSocket, %{"token" => token})
      {:ok, _, socket2} = subscribe_and_join(socket2, "workers:crf_search")
      assert_reply push(socket2, "announce", announce_payload(worker_id: "worker-crf")), :ok

      assert_reply push(socket2, "job_active", %{
                     "job_id" => job_id,
                     "video_id" => video.id,
                     "job_type" => "crf_search"
                   }),
                   :ok,
                   %{accepted: true, event: "job_active"}

      assert_reply push(socket2, "crf_search_progress", %{
                     "job_id" => job_id,
                     "video_id" => video.id,
                     "percent" => 25.0
                   }),
                   :ok,
                   %{accepted: true, event: "crf_search_progress"}

      assert WorkerSessions.get(socket2.assigns.worker_id).jobs[job_id].progress.percent == 25.0
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "assigns encode work only when the worker requests encode" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)
      previous_temp_dir = Application.get_env(:reencodarr, :temp_dir)
      temp_dir = Path.join(System.tmp_dir!(), "worker-encode-output-#{System.unique_integer()}")
      Application.put_env(:reencodarr, :temp_dir, temp_dir)
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())
      path = Path.join(System.tmp_dir!(), "worker-encode-#{System.unique_integer()}.mkv")
      File.write!(path, "source")

      on_exit(fn ->
        File.rm(path)
        File.rm_rf(temp_dir)

        if is_nil(previous_temp_dir),
          do: Application.delete_env(:reencodarr, :temp_dir),
          else: Application.put_env(:reencodarr, :temp_dir, previous_temp_dir)
      end)

      {:ok, video} = Fixtures.video_fixture(%{path: path, size: 6, state: :crf_searched})
      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 30.0, params: []})
      _video = Fixtures.choose_vmaf(video, vmaf)

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")

      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-encode")),
                   :ok,
                   %{accepted: true}

      report_disk_capacity(socket)

      assert_reply push(socket, "pull_work", %{"job_type" => "crf_search"}),
                   :ok,
                   %{status: "no_work"}

      assert_reply push(socket, "pull_work", %{"job_type" => "encode"}),
                   :ok,
                   %{
                     status: "job_assigned",
                     job_type: "encode",
                     job_id: "encode-" <> _ = job_id,
                     video_id: video_id,
                     encode_args: ["encode" | _]
                   }

      assert video_id == video.id

      assert %{
               state: :encoding,
               encode_worker_id: "worker-encode",
               worker_attempt_id: ^job_id
             } = Media.get_video(video.id)

      assert_receive {:encoding_started,
                      %{
                        video_id: ^video_id,
                        filename: filename,
                        crf: 30.0,
                        video_size: 6
                      }}

      assert filename == Path.basename(path)

      assert {:ok, command} = Media.request_worker_control(video.id, job_id, :pause)

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        WorkerChannel.worker_control_topic(socket.assigns.worker_id),
        {:worker_control, :pause, job_id, command.command_id}
      )

      assert_push "control", %{
        action: "pause",
        command_id: command_id,
        job_id: "encode-" <> _,
        video_id: ^video_id
      }

      assert command_id == command.command_id

      assert_reply push(socket, "encode_progress", %{
                     "job_id" => job_id,
                     "video_id" => video.id,
                     "percent" => 50.0,
                     "fps" => 12.5,
                     "eta" => 30,
                     "output_bytes" => 3,
                     "output_percent" => 50.0,
                     "throughput" => "12.50 fps"
                   }),
                   :ok,
                   %{accepted: true, event: "encode_progress"}

      assert_receive {:encoding_progress,
                      %{job_id: "encode-" <> _, video_id: ^video_id, output_bytes: 3}}

      output_path = Encode.output_file(Media.get_video(video.id))
      File.write!(output_path, "encoded")
      :meck.new(Reencodarr.PostProcessor, [:passthrough])

      on_exit(fn ->
        try do
          :meck.unload(Reencodarr.PostProcessor)
        catch
          :error, {:not_mocked, _module} -> :ok
        end
      end)

      :meck.expect(Reencodarr.PostProcessor, :process_encoding_success, fn _video, ^output_path ->
        {:ok, :success}
      end)

      assert_reply push(socket, "encode_completed", %{
                     "job_id" => job_id,
                     "video_id" => video.id,
                     "source_name" => Path.basename(video.path),
                     "output_path" => "/remote/worker/output.mkv",
                     "output_bytes" => 7,
                     "output_percent" => 116.67
                   }),
                   :ok,
                   %{accepted: true, event: "encode_completed"}

      assert :meck.validate(Reencodarr.PostProcessor)
      assert_receive {:encoding_completed, %{job_id: "encode-" <> _, video_id: ^video_id}}
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "fails unsupported object audio and moves to the next encode request" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      path =
        Path.join(System.tmp_dir!(), "worker-unsupported-audio-#{System.unique_integer()}.mkv")

      File.write!(path, "source")

      on_exit(fn -> File.rm(path) end)

      mediainfo = %{
        "media" => %{
          "track" => [
            %{"@type" => "General", "Format" => "Matroska"},
            %{"@type" => "Video", "Format" => "AVC", "Width" => "1920", "Height" => "1080"},
            %{
              "@type" => "Audio",
              "Format" => "IAMF",
              "CodecID" => "iamf",
              "Channels" => "6",
              "ChannelLayout" => "5.1"
            }
          ]
        }
      }

      {:ok, video} =
        Fixtures.video_fixture(%{
          path: path,
          size: 6,
          state: :crf_searched,
          mediainfo: mediainfo
        })

      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 30.0, params: []})
      _video = Fixtures.choose_vmaf(video, vmaf)

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")

      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-unsupported")),
                   :ok

      report_disk_capacity(socket)

      assert_reply push(socket, "pull_work", %{"job_type" => "encode"}),
                   :ok,
                   %{status: "no_work"}

      assert Media.get_video(video.id).state == :failed

      assert [%{failure_category: :configuration, failure_stage: :encoding}] =
               Media.get_video_failures(video.id)
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "does not claim encode work without fresh worker disk capacity" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/remote/capacity-check.mkv",
          size: 10_000,
          state: :crf_searched
        })

      vmaf =
        Fixtures.vmaf_fixture(%{video_id: video.id, crf: 30.0, percent: 40.0, params: []})

      Fixtures.choose_vmaf(video, vmaf)

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")

      assert_reply push(
                     socket,
                     "announce",
                     announce_payload(
                       worker_id: "capacity-worker",
                       capabilities: %{"crf_search" => true, "encode" => true}
                     )
                   ),
                   :ok,
                   %{accepted: true}

      assert_reply push(socket, "pull_work", %{"job_type" => "encode"}),
                   :ok,
                   %{status: "no_work"}

      assert Media.get_video(video.id).state == :crf_searched

      assert %{status: :blocked, reason: :missing_disk_telemetry} =
               WorkerSessions.get(socket.assigns.worker_id).encode_admission

      assert_reply push(socket, "heartbeat", %{"disk_free_bytes" => 1}),
                   :ok,
                   %{accepted: true}

      assert_reply push(socket, "pull_work", %{"job_type" => "encode"}),
                   :ok,
                   %{status: "no_work"}

      assert Media.get_video(video.id).state == :crf_searched

      assert %{
               status: :blocked,
               reason: :insufficient_disk_space,
               available_bytes: 1,
               required_bytes: required_bytes
             } = WorkerSessions.get(socket.assigns.worker_id).encode_admission

      assert required_bytes > 1

      assert_reply push(socket, "heartbeat", %{"disk_free_bytes" => 20_000_000_000}),
                   :ok,
                   %{accepted: true}

      assert_reply push(socket, "pull_work", %{"job_type" => "encode"}),
                   :ok,
                   %{status: "job_assigned", video_id: assigned_video_id}

      assert assigned_video_id == video.id
      assert WorkerSessions.get(socket.assigns.worker_id).encode_admission.status == :allowed
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "reattaches an active encode after websocket reconnect" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      path =
        Path.join(System.tmp_dir!(), "worker-encode-reconnect-#{System.unique_integer()}.mkv")

      File.write!(path, "source")
      on_exit(fn -> File.rm(path) end)

      {:ok, video} = Fixtures.video_fixture(%{path: path, size: 6, state: :crf_searched})
      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id, params: []})
      Fixtures.choose_vmaf(video, vmaf)

      {:ok, socket1} = connect(WorkerSocket, %{"token" => token})
      {:ok, _, socket1} = subscribe_and_join(socket1, "workers:crf_search")
      assert_reply push(socket1, "announce", announce_payload(worker_id: "worker-reconnect")), :ok
      report_disk_capacity(socket1)

      assert_reply push(socket1, "pull_work", %{"job_type" => "encode"}),
                   :ok,
                   %{job_id: job_id}

      old_server_id = socket1.assigns.worker_id
      Process.unlink(socket1.channel_pid)
      assert :ok = close(socket1)

      assert [%{jobs: jobs}] = WorkerSessions.list()
      assert %{video_id: video_id} = jobs[job_id]
      assert video_id == video.id

      {:ok, socket2} = connect(WorkerSocket, %{"token" => token})
      {:ok, _, socket2} = subscribe_and_join(socket2, "workers:crf_search")
      assert_reply push(socket2, "announce", announce_payload(worker_id: "worker-reconnect")), :ok
      refute socket2.assigns.worker_id == old_server_id
      refute WorkerSessions.get(socket2.assigns.worker_id).jobs[job_id].active

      assert_reply push(socket2, "pull_work", %{"job_type" => "encode"}),
                   :ok,
                   %{status: "job_in_progress", job_id: ^job_id, video_id: ^video_id}

      assert is_nil(WorkerSessions.get(old_server_id))

      resumed_job = WorkerSessions.get(socket2.assigns.worker_id).jobs[job_id]
      assert resumed_job.video_id == video.id
      assert resumed_job.active
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "recovers only the persisted encode attempt after server state is lost" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      path =
        Path.join(
          System.tmp_dir!(),
          "worker-encode-server-restart-#{System.unique_integer()}.mkv"
        )

      File.write!(path, "source")
      on_exit(fn -> File.rm(path) end)

      {:ok, video} = Fixtures.video_fixture(%{path: path, size: 6, state: :crf_searched})
      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id, params: []})
      Fixtures.choose_vmaf(video, vmaf)

      {:ok, socket1} = connect(WorkerSocket, %{"token" => token})
      {:ok, _, socket1} = subscribe_and_join(socket1, "workers:crf_search")
      assert_reply push(socket1, "announce", announce_payload(worker_id: "worker-restart")), :ok
      report_disk_capacity(socket1)

      assert_reply push(socket1, "pull_work", %{"job_type" => "encode"}),
                   :ok,
                   %{job_id: job_id}

      Process.unlink(socket1.channel_pid)
      assert :ok = close(socket1)

      :ok = WorkerSessions.reset()

      {:ok, socket2} = connect(WorkerSocket, %{"token" => token})
      {:ok, _, socket2} = subscribe_and_join(socket2, "workers:crf_search")
      assert_reply push(socket2, "announce", announce_payload(worker_id: "worker-restart")), :ok

      assert_reply push(socket2, "job_active", %{
                     "job_id" => job_id,
                     "video_id" => video.id,
                     "job_type" => "encode"
                   }),
                   :ok,
                   %{accepted: true, event: "job_active"}

      assert_reply push(socket2, "encode_progress", %{
                     "job_id" => job_id,
                     "video_id" => video.id,
                     "percent" => 42.0,
                     "fps" => 12.5,
                     "eta" => 90,
                     "output_bytes" => 1_000,
                     "output_percent" => 10.0,
                     "throughput" => "12.50 fps"
                   }),
                   :ok,
                   %{accepted: true, event: "encode_progress"}

      assert %WorkerProtocol.EncodeProgress{percent: 42.0} =
               WorkerSessions.get(socket2.assigns.worker_id).jobs[job_id].progress

      assert Media.get_video(video.id).state == :encoding
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "rejects encode progress from a superseded attempt" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      {:ok, video} = Fixtures.video_fixture(%{state: :crf_searched})
      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id, params: []})
      video = Fixtures.choose_vmaf(video, vmaf)

      {:ok, video} =
        Media.mark_as_encoding(video, %{
          encode_worker_id: "worker-new",
          worker_attempt_id: "encode-new"
        })

      {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      {:ok, _, socket} = subscribe_and_join(socket, "workers:crf_search")
      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-old")), :ok

      assert_reply push(socket, "encode_progress", %{
                     "job_id" => "encode-old",
                     "video_id" => video.id,
                     "percent" => 42.0,
                     "fps" => 12.5,
                     "output_bytes" => 1_000,
                     "output_percent" => 10.0
                   }),
                   :error,
                   %{reason: "unknown_worker_session"}

      assert %{
               state: :encoding,
               encode_worker_id: "worker-new",
               worker_attempt_id: "encode-new"
             } = Media.get_video(video.id)

      assert WorkerSessions.get(socket.assigns.worker_id).jobs == %{}
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "rejects late encode progress after the attempt stopped" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      {:ok, video} =
        Fixtures.video_fixture(%{
          state: :encoding,
          encode_worker_id: "worker-stopped",
          worker_attempt_id: "encode-stopped"
        })

      {:ok, _video} = Media.mark_as_failed(video)

      {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      {:ok, _, socket} = subscribe_and_join(socket, "workers:crf_search")
      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-stopped")), :ok

      assert_reply push(socket, "encode_progress", %{
                     "job_id" => "encode-stopped",
                     "video_id" => video.id,
                     "percent" => 42.0,
                     "fps" => 12.5,
                     "output_bytes" => 1_000,
                     "output_percent" => 10.0
                   }),
                   :error,
                   %{reason: "unknown_worker_session"}

      assert Media.get_video(video.id).state == :failed
      assert WorkerSessions.get(socket.assigns.worker_id).jobs == %{}
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "acknowledges replayed encode completion for the same finished attempt" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      {:ok, video} =
        Fixtures.video_fixture(%{
          state: :encoded,
          encode_worker_id: "worker-replay",
          worker_attempt_id: "encode-finished"
        })

      {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      {:ok, _, socket} = subscribe_and_join(socket, "workers:crf_search")
      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-replay")), :ok

      assert_reply push(socket, "encode_completed", %{
                     "job_id" => "encode-finished",
                     "video_id" => video.id,
                     "source_name" => Path.basename(video.path),
                     "output_path" => "/already/moved.mkv",
                     "output_bytes" => 1,
                     "output_percent" => 1.0
                   }),
                   :ok,
                   %{accepted: true, event: "encode_completed"}

      assert Media.get_video(video.id).state == :encoded
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "does not acknowledge a duplicate while the exact terminal attempt is processing" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      {:ok, video} =
        Fixtures.video_fixture(%{
          state: :encoding,
          encode_worker_id: "worker-terminal",
          worker_attempt_id: "encode-terminal",
          worker_terminal_claimed_at: DateTime.utc_now()
        })

      {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      {:ok, _, socket} = subscribe_and_join(socket, "workers:crf_search")
      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-terminal")), :ok

      assert_reply push(socket, "encode_completed", %{
                     "job_id" => "encode-terminal",
                     "video_id" => video.id,
                     "source_name" => Path.basename(video.path),
                     "output_path" => "/worker/output.mkv",
                     "output_bytes" => 1,
                     "output_percent" => 1.0
                   }),
                   :error,
                   %{reason: "terminal_busy"}

      assert Media.get_video(video.id).state == :encoding
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "retires replayed encode completion from a different attempt" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      {:ok, video} =
        Fixtures.video_fixture(%{
          state: :encoded,
          encode_worker_id: "worker-replay",
          worker_attempt_id: "encode-finished"
        })

      {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      {:ok, _, socket} = subscribe_and_join(socket, "workers:crf_search")
      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-replay")), :ok

      assert_reply push(socket, "encode_completed", %{
                     "job_id" => "encode-stale",
                     "video_id" => video.id,
                     "source_name" => Path.basename(video.path),
                     "output_path" => "/already/moved.mkv",
                     "output_bytes" => 1,
                     "output_percent" => 1.0
                   }),
                   :ok,
                   %{
                     accepted: false,
                     discarded: true,
                     event: "encode_completed",
                     reason: "unknown_worker_session"
                   }
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "retires stale CRF completion and worker failures without mutating videos" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      {:ok, crf_video} = Fixtures.video_fixture(%{state: :analyzed})
      {:ok, encode_video} = Fixtures.video_fixture(%{state: :crf_searched})

      {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      {:ok, _, socket} = subscribe_and_join(socket, "workers:crf_search")
      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-stale")), :ok

      assert_reply push(socket, "crf_search_completed", %{
                     "job_id" => "crf-stale",
                     "video_id" => crf_video.id,
                     "result" => "ok"
                   }),
                   :ok,
                   %{
                     accepted: false,
                     discarded: true,
                     event: "crf_search_completed",
                     reason: "unknown_worker_session"
                   }

      for {video, stage} <- [{crf_video, "crf_search"}, {encode_video, "encoding"}] do
        assert_reply push(socket, "video_failed", %{
                       "job_id" => "#{stage}-stale",
                       "video_id" => video.id,
                       "stage" => stage,
                       "category" => "process_failure",
                       "message" => "stale failure",
                       "code" => "EXIT_1",
                       "context" => %{}
                     }),
                     :ok,
                     %{
                       accepted: false,
                       discarded: true,
                       event: "video_failed",
                       reason: "unknown_worker_session"
                     }
      end

      assert Media.get_video(crf_video.id).state == :analyzed
      assert Media.get_video(encode_video.id).state == :crf_searched
      assert Media.get_video_failures(crf_video.id) == []
      assert Media.get_video_failures(encode_video.id) == []
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "retires a stopped acknowledgement from a superseded job" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      {:ok, video} =
        Fixtures.video_fixture(%{
          state: :encoding,
          encode_worker_id: "worker-new",
          worker_attempt_id: "encode-new"
        })

      {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      {:ok, _, socket} = subscribe_and_join(socket, "workers:crf_search")
      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-old")), :ok

      assert {:ok, _session} =
               WorkerSessions.assign_job(socket.assigns.worker_id, %WorkerSessions.Job{
                 job_id: "encode-old",
                 job_type: :encode,
                 video_id: video.id
               })

      assert_reply push(socket, "control_state", %{
                     "state" => "stopped",
                     "job_id" => "encode-old",
                     "command_id" => "stale-command"
                   }),
                   :ok,
                   %{
                     accepted: false,
                     discarded: true,
                     event: "control_state",
                     reason: "unknown_worker_session"
                   }

      assert %{
               state: :encoding,
               encode_worker_id: "worker-new",
               worker_attempt_id: "encode-new"
             } = Media.get_video(video.id)
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "records an encode failure once and acknowledges its replay" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      {:ok, video} =
        Fixtures.video_fixture(%{
          state: :encoding,
          encode_worker_id: "worker-failure",
          worker_attempt_id: "encode-failure"
        })

      {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      {:ok, _, socket} = subscribe_and_join(socket, "workers:crf_search")
      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-failure")), :ok

      payload = %{
        "job_id" => "encode-failure",
        "video_id" => video.id,
        "stage" => "encoding",
        "category" => "process_failure",
        "message" => "encoder exited",
        "code" => "EXIT_254",
        "context" => %{}
      }

      assert_reply push(socket, "video_failed", payload),
                   :ok,
                   %{accepted: true, event: "video_failed"}

      assert Media.get_video(video.id).state == :failed
      assert [%{failure_code: "EXIT_254"}] = Media.get_video_failures(video.id)

      assert_reply push(socket, "video_failed", payload),
                   :ok,
                   %{accepted: true, event: "video_failed"}

      assert [_failure] = Media.get_video_failures(video.id)
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "offers a loopback worker the local source instead of starting a transfer" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      path =
        Path.join(System.tmp_dir!(), "local-worker-#{System.unique_integer([:positive])}.mkv")

      File.write!(path, "data")
      on_exit(fn -> File.rm(path) end)
      {:ok, video} = Fixtures.video_fixture(%{path: path, size: 4, state: :analyzed})

      assert {:ok, socket} =
               connect(WorkerSocket, %{"token" => token},
                 connect_info: %{peer_data: %{address: {0, 0, 0, 0, 0, 65_535, 32_512, 1}}}
               )

      assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")

      assert_reply push(
                     socket,
                     "announce",
                     announce_payload(
                       worker_id: "local-worker",
                       hostname: :inet.gethostname() |> elem(1) |> List.to_string()
                     )
                   ),
                   :ok

      assert_reply push(socket, "pull_work", %{}),
                   :ok,
                   %{status: "job_assigned", local_path: local_path}

      assert local_path == video.path
      assert WorkerSessions.get(socket.assigns.worker_id).phase == :input_ready
      refute_receive :stream_transfer_chunk
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "fails a local assignment whose source no longer exists" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      path = Path.join(System.tmp_dir!(), "missing-local-worker-#{System.unique_integer()}.mkv")
      {:ok, video} = Fixtures.video_fixture(%{path: path, size: 4, state: :analyzed})

      assert {:ok, socket} =
               connect(WorkerSocket, %{"token" => token},
                 connect_info: %{peer_data: %{address: {127, 0, 0, 1}}}
               )

      assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")

      assert_reply push(
                     socket,
                     "announce",
                     announce_payload(
                       worker_id: "local-worker",
                       hostname: :inet.gethostname() |> elem(1) |> List.to_string()
                     )
                   ),
                   :ok

      assert_reply push(socket, "pull_work", %{}), :error, %{reason: "source_missing"}
      assert Media.get_video(video.id).state == :failed
      refute_receive :stream_transfer_chunk
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "uses the current source size when assigning worker input" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      path =
        Path.join(
          System.tmp_dir!(),
          "worker-transfer-size-#{System.unique_integer([:positive])}.mkv"
        )

      File.write!(path, :binary.copy(<<0>>, 64))
      on_exit(fn -> File.rm(path) end)

      {:ok, video} = Fixtures.video_fixture(%{path: path, size: 128, state: :analyzed})
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")

      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-size")),
                   :ok,
                   %{accepted: true}

      assert_reply push(socket, "pull_work", %{}),
                   :ok,
                   %{video_id: video_id, size_bytes: 64}

      assert video_id == video.id
      assert Media.get_video(video.id).size == 64
      refute_receive {:sync_started, _}, 50
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

    test "heartbeat acknowledgement does not wait for worker session storage" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      {:ok, _, socket} = subscribe_and_join(socket, "workers:crf_search")
      assert_reply push(socket, "announce", announce_payload()), :ok

      sessions = Process.whereis(WorkerSessions)
      :ok = :sys.suspend(sessions)
      on_exit(fn -> :sys.resume(sessions) end)

      ref = push(socket, "heartbeat", %{"cpu_percent" => 50.0})

      assert_reply ref, :ok, %{accepted: true}, 100
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "progress acknowledgements do not wait for worker session storage" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)
      {:ok, video} = Fixtures.video_fixture(%{state: :analyzed})

      {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      {:ok, _, socket} = subscribe_and_join(socket, "workers:crf_search")
      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-progress")), :ok
      assert_reply push(socket, "pull_work", %{}), :ok, %{job_id: job_id}

      track_video_lookups()

      sessions = Process.whereis(WorkerSessions)
      :ok = :sys.suspend(sessions)
      on_exit(fn -> :sys.resume(sessions) end)

      ref =
        push(socket, "transfer_progress", %{
          "job_id" => job_id,
          "video_id" => video.id,
          "percent" => 5.0,
          "received_bytes" => 5,
          "expected_bytes" => 100
        })

      assert_reply ref, :ok, %{accepted: true, event: "transfer_progress"}, 100

      ref =
        push(socket, "crf_search_progress", %{
          "job_id" => job_id,
          "video_id" => video.id,
          "percent" => 5.0,
          "fps" => 30.0,
          "crf" => 28.0,
          "sample_num" => 1,
          "total_samples" => 5
        })

      assert_reply ref, :ok, %{accepted: true, event: "crf_search_progress"}, 100
      refute_receive {:media_get_video, _video_id}
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "encode progress acknowledgement does not wait for worker session storage" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)
      path = Path.join(System.tmp_dir!(), "worker-progress-#{System.unique_integer()}.mkv")
      File.write!(path, "source")
      on_exit(fn -> File.rm(path) end)

      {:ok, video} = Fixtures.video_fixture(%{path: path, size: 6, state: :crf_searched})
      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id, params: []})
      Fixtures.choose_vmaf(video, vmaf)

      {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      {:ok, _, socket} = subscribe_and_join(socket, "workers:crf_search")

      assert_reply push(
                     socket,
                     "announce",
                     announce_payload(
                       worker_id: "worker-encode-progress",
                       capabilities: %{"crf_search" => true, "encode" => true}
                     )
                   ),
                   :ok

      report_disk_capacity(socket)

      assert_reply push(socket, "pull_work", %{"job_type" => "encode"}),
                   :ok,
                   %{job_id: job_id}

      track_video_lookups()

      sessions = Process.whereis(WorkerSessions)
      :ok = :sys.suspend(sessions)
      on_exit(fn -> :sys.resume(sessions) end)

      ref =
        push(socket, "encode_progress", %{
          "job_id" => job_id,
          "video_id" => video.id,
          "percent" => 5.0,
          "fps" => 30.0,
          "output_bytes" => 100,
          "output_percent" => 1.0
        })

      assert_reply ref, :ok, %{accepted: true, event: "encode_progress"}, 100
      refute_receive {:media_get_video, _video_id}
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
                   %{status: "job_assigned", video_id: ^video_id, job_id: job_id}

      assert_reply push(socket, "transfer_progress", %{
                     "video_id" => video_id,
                     "job_id" => job_id,
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
                        transfer_id: ^job_id,
                        job_id: ^job_id,
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
                     "job_id" => job_id,
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
                     "job_id" => job_id,
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

      assert {:ok, command} = Media.request_worker_control(video_id, job_id, :pause)

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        WorkerChannel.worker_control_topic(server_worker_id),
        {:worker_control, :pause, job_id, command.command_id}
      )

      assert_push "control", %{
        action: "pause",
        command_id: command_id,
        job_id: ^job_id,
        video_id: ^video_id
      }

      assert command_id == command.command_id

      assert_reply push(socket, "control_state", %{
                     "state" => "paused",
                     "active_video_id" => video_id,
                     "job_id" => job_id,
                     "command_id" => command.command_id
                   }),
                   :ok,
                   %{accepted: true, state: "paused"}

      assert WorkerSessions.get(server_worker_id).jobs[job_id].control_state == :paused
      assert WorkerSessions.get(server_worker_id).control_state == :running

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        WorkerChannel.worker_control_topic(server_worker_id),
        {:worker_control, :stop}
      )

      assert_push "control", %{action: "stop"}

      assert_reply push(socket, "control_state", %{"state" => "stopped"}),
                   :ok,
                   %{accepted: true, state: "stopped"}

      assert WorkerSessions.get(server_worker_id).control_state == :stopped
      assert Media.get_video(video_id).state == :failed
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "accepts resumed CRF progress for already-searching video after reconnect" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      job_id = "crf-resume"

      {:ok, video} =
        Fixtures.video_fixture(%{
          state: :crf_searching,
          crf_search_worker_id: "worker-a",
          worker_attempt_id: job_id
        })

      video_id = video.id

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")
      server_worker_id = socket.assigns.worker_id

      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-a")),
                   :ok,
                   %{accepted: true, protocol_version: 1}

      session = WorkerSessions.get(server_worker_id)
      assert is_nil(session.active_video_id)

      assert_reply push(socket, "job_active", %{
                     "job_id" => job_id,
                     "video_id" => video_id,
                     "job_type" => "crf_search"
                   }),
                   :ok,
                   %{accepted: true, event: "job_active"}

      assert_reply push(socket, "crf_search_progress", %{
                     "job_id" => job_id,
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

    test "restores paused work from a control acknowledgment after server state is lost" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      job_id = "crf-restored-control"

      {:ok, video} =
        Fixtures.video_fixture(%{
          state: :crf_searching,
          crf_search_worker_id: "worker-a",
          worker_attempt_id: job_id,
          worker_control_desired_state: :running,
          worker_control_acknowledged_state: :running
        })

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")
      server_worker_id = socket.assigns.worker_id

      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-a")), :ok
      assert is_nil(WorkerSessions.get(server_worker_id).active_video_id)

      assert {:ok, pause_command} = Media.request_worker_control(video.id, job_id, :pause)

      assert_reply push(socket, "control_state", %{
                     "state" => "paused",
                     "active_video_id" => video.id,
                     "job_id" => job_id,
                     "command_id" => pause_command.command_id
                   }),
                   :ok

      session = WorkerSessions.get(server_worker_id)
      assert session.control_state == :running
      assert session.active_video_id == video.id
      assert session.jobs[job_id].control_state == :paused

      assert {:ok, stop_command} = Media.request_worker_control(video.id, job_id, :stop)

      assert_reply push(socket, "control_state", %{
                     "state" => "stopped",
                     "active_video_id" => video.id,
                     "job_id" => job_id,
                     "command_id" => stop_command.command_id
                   }),
                   :ok

      assert_reply push(socket, "control_state", %{
                     "state" => "stopped",
                     "active_video_id" => video.id,
                     "job_id" => job_id,
                     "command_id" => stop_command.command_id
                   }),
                   :ok

      assert Media.get_video(video.id).state == :failed
      assert [_failure] = Media.get_video_failures(video.id)
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "replays a persisted unacknowledged job control after reconnect" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)
      job_id = "encode-reconnect-control"

      {:ok, video} =
        Fixtures.video_fixture(%{
          state: :encoding,
          encode_worker_id: "worker-reconnect",
          worker_attempt_id: job_id,
          worker_control_desired_state: :running,
          worker_control_acknowledged_state: :running
        })

      assert {:ok, _session} =
               WorkerSessions.register(%{
                 server_worker_id: "disconnected-server-id",
                 client_worker_id: "worker-reconnect",
                 protocol_version: 1,
                 version: "0.11.4",
                 capabilities: %{"crf_search" => true, "encode" => true}
               })

      assert {:ok, _session} =
               WorkerSessions.assign_job("disconnected-server-id", %WorkerSessions.Job{
                 job_id: job_id,
                 job_type: :encode,
                 video_id: video.id,
                 phase: :encoding
               })

      assert {:ok, command} = Media.request_worker_control(video.id, job_id, :pause)

      assert {:ok, _session} =
               WorkerSessions.request_job_control(
                 "disconnected-server-id",
                 job_id,
                 :paused,
                 command.command_id
               )

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")

      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-reconnect")),
                   :ok

      assert_push "control", %{
        action: "pause",
        command_id: command_id,
        job_id: ^job_id,
        video_id: video_id
      }

      assert command_id == command.command_id
      assert video_id == video.id

      assert_reply push(socket, "control_state", %{
                     "state" => "paused",
                     "active_video_id" => video.id,
                     "job_id" => job_id,
                     "command_id" => command.command_id
                   }),
                   :ok

      assert Media.get_video(video.id).worker_control_acknowledged_state == :paused
      assert WorkerSessions.get(socket.assigns.worker_id).jobs[job_id].control_state == :paused
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "does not restart transfer when reconnected worker asks for work already in progress" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      job_id = "crf-in-progress"

      {:ok, video} =
        Fixtures.video_fixture(%{
          state: :crf_searching,
          crf_search_worker_id: "worker-a",
          worker_attempt_id: job_id
        })

      video_id = video.id

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      assert {:ok, _join_payload, socket} = subscribe_and_join(socket, "workers:crf_search")
      server_worker_id = socket.assigns.worker_id

      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-a")),
                   :ok,
                   %{accepted: true, protocol_version: 1}

      assert_reply push(socket, "job_active", %{
                     "job_id" => job_id,
                     "video_id" => video_id,
                     "job_type" => "crf_search"
                   }),
                   :ok,
                   %{accepted: true, event: "job_active"}

      assert_reply push(socket, "crf_search_progress", %{
                     "job_id" => job_id,
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

      assert :ok =
               WorkerSessions.set_transfer_progress(server_worker_id, %{
                 job_id: job_id,
                 video_id: video_id,
                 transfer_id: job_id,
                 filename: Path.basename(video.path),
                 percent: 100.0,
                 bytes_sent: 8,
                 total_bytes: 8
               })

      session = WorkerSessions.get(server_worker_id)

      assert session.phase == :input_ready
      assert session.active_video_id == video_id
      assert is_nil(session.crf_search_progress)

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
            size: 16,
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
                     %{status: "job_in_progress", video_id: ^video_id, size_bytes: 8}

        assert Media.get_video(video_id).size == 8
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
                   %{
                     status: "job_assigned",
                     video_id: ^video_id,
                     job_id: job_id,
                     crf_search_args: assigned_args
                   }

      assert_reply push(socket, "crf_search_progress", %{
                     "job_id" => job_id,
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
        job_id = "crf-resume"

        assert %Media.Video{id: ^video_id} =
                 Media.claim_next_video_for_crf_search("worker-a", job_id)

        assert {:ok, _session} =
                 WorkerSessions.register(%{
                   server_worker_id: "worker-server-1",
                   client_worker_id: "worker-a",
                   protocol_version: 1,
                   version: "0.10.0",
                   capabilities: %{"crf_search" => true}
                 })

        assert {:ok, _session} =
                 WorkerSessions.assign_video(
                   "worker-server-1",
                   video_id,
                   :receiving_input,
                   job_id
                 )

        assert :ok =
                 WorkerSessions.set_transfer_progress("worker-server-1", %{
                   job_id: job_id,
                   transfer_id: job_id,
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

        assert transfer_id == job_id
      end)
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "reports transfer failure instead of silently waiting when resend input is unavailable" do
      token = "test-worker-token"
      Application.put_env(:reencodarr, :worker_token, token)

      missing_path =
        Path.join(System.tmp_dir!(), "missing-worker-input-#{System.unique_integer()}.mkv")

      {:ok, video} =
        Fixtures.video_fixture(%{
          state: :crf_searching,
          path: missing_path,
          size: 8,
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
                   %{status: "job_assigned", video_id: ^video_id}

      assert_push "transfer_failed", %{
        status: "transfer_failed",
        video_id: ^video_id,
        transfer_id: transfer_id
      }

      assert transfer_id == Integer.to_string(video_id)
      refute_push "transfer_started", _, 50
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

    test "streams CRF and encode inputs independently on one socket" do
      token = "test-worker-token"
      previous_chunk_size = Application.get_env(:reencodarr, :worker_chunk_size_bytes)
      Application.put_env(:reencodarr, :worker_token, token)
      Application.put_env(:reencodarr, :worker_chunk_size_bytes, 4)

      crf_path = Path.join(System.tmp_dir!(), "worker-crf-dual-#{System.unique_integer()}.mkv")

      encode_path =
        Path.join(System.tmp_dir!(), "worker-encode-dual-#{System.unique_integer()}.mkv")

      File.write!(crf_path, "abcdefgh")
      File.write!(encode_path, "12345678")

      on_exit(fn ->
        File.rm(crf_path)
        File.rm(encode_path)

        if is_nil(previous_chunk_size),
          do: Application.delete_env(:reencodarr, :worker_chunk_size_bytes),
          else:
            Application.put_env(
              :reencodarr,
              :worker_chunk_size_bytes,
              previous_chunk_size
            )
      end)

      {:ok, crf_video} =
        Fixtures.video_fixture(%{path: crf_path, size: 8, state: :analyzed})

      {:ok, encode_video} =
        Fixtures.video_fixture(%{path: encode_path, size: 8, state: :crf_searched})

      vmaf = Fixtures.vmaf_fixture(%{video_id: encode_video.id, params: []})
      Fixtures.choose_vmaf(encode_video, vmaf)

      {:ok, socket} = connect(WorkerSocket, %{"token" => token})
      {:ok, _, socket} = subscribe_and_join(socket, "workers:crf_search")
      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-dual")), :ok
      report_disk_capacity(socket)

      assert_reply push(socket, "pull_work", %{"job_type" => "crf_search"}),
                   :ok,
                   %{job_id: crf_job_id}

      assert_reply push(socket, "pull_work", %{"job_type" => "encode"}),
                   :ok,
                   %{job_id: encode_job_id}

      assert_push "transfer_started", %{transfer_id: first_started}
      assert_push "transfer_started", %{transfer_id: second_started}

      assert MapSet.new([first_started, second_started]) ==
               MapSet.new([crf_job_id, encode_job_id])

      assert_push "transfer_chunk", {:binary, first_frame}
      assert_push "transfer_chunk", {:binary, second_frame}
      {:ok, first_chunk} = WorkerProtocol.parse_transfer_chunk_frame(first_frame)
      {:ok, second_chunk} = WorkerProtocol.parse_transfer_chunk_frame(second_frame)
      chunks = Map.new([first_chunk, second_chunk], &{&1.transfer_id, &1})
      assert chunks[crf_job_id].data == "abcd"
      assert chunks[encode_job_id].data == "1234"

      assert_reply push(socket, "transfer_progress", %{
                     "job_id" => encode_job_id,
                     "video_id" => encode_video.id,
                     "percent" => 50.0,
                     "bytes_sent" => 4,
                     "total_bytes" => 8
                   }),
                   :ok

      assert_reply push(socket, "transfer_progress", %{
                     "job_id" => crf_job_id,
                     "video_id" => crf_video.id,
                     "percent" => 50.0,
                     "bytes_sent" => 4,
                     "total_bytes" => 8
                   }),
                   :ok

      assert_push "transfer_chunk", {:binary, third_frame}
      assert_push "transfer_chunk", {:binary, fourth_frame}
      {:ok, third_chunk} = WorkerProtocol.parse_transfer_chunk_frame(third_frame)
      {:ok, fourth_chunk} = WorkerProtocol.parse_transfer_chunk_frame(fourth_frame)
      final_chunks = Map.new([third_chunk, fourth_chunk], &{&1.transfer_id, &1.data})
      assert final_chunks[crf_job_id] == "efgh"
      assert final_chunks[encode_job_id] == "5678"
    after
      Application.delete_env(:reencodarr, :worker_token)
    end

    test "accepts encode transfer progress when no websocket transfer is assigned" do
      server_worker_id = "worker-server-encode-progress"
      client_worker_id = "worker-client-encode-progress"
      {:ok, video} = Fixtures.video_fixture(%{state: :crf_searched})
      video_id = video.id
      job_id = "encode-#{video_id}"

      {:ok, _video} =
        Media.mark_as_encoding(video, %{
          encode_worker_id: client_worker_id,
          worker_attempt_id: job_id
        })

      {:ok, _session} =
        WorkerSessions.register(%{
          server_worker_id: server_worker_id,
          client_worker_id: client_worker_id,
          version: "0.11.4",
          protocol_version: 1,
          capabilities: %{"encode" => true}
        })

      {:ok, _session} =
        WorkerSessions.assign_job(server_worker_id, %WorkerSessions.Job{
          job_id: job_id,
          job_type: :encode,
          video_id: video_id,
          phase: :receiving_input
        })

      socket = %Phoenix.Socket{
        assigns: %{
          worker_id: server_worker_id,
          client_worker_id: client_worker_id,
          encode_job_id: job_id,
          encode_video_id: video_id
        }
      }

      assert {:reply, {:ok, %{accepted: true, event: "transfer_progress"}}, ^socket} =
               WorkerChannel.handle_in(
                 "transfer_progress",
                 %{
                   "job_id" => job_id,
                   "transfer_id" => job_id,
                   "video_id" => video_id,
                   "percent" => 50.0,
                   "received_bytes" => 1024,
                   "expected_bytes" => 2048
                 },
                 socket
               )

      session = WorkerSessions.get(server_worker_id)
      assert session.jobs[job_id].phase == :receiving_input
      assert session.jobs[job_id].transfer_progress.percent == 50.0
      assert session.jobs[job_id].transfer_progress.bytes_sent == 1024
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
                   %{status: "job_assigned", video_id: ^video_id, job_id: job_id}

      assert_reply push(socket, "crf_search_result", %{
                     "job_id" => job_id,
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
                     "job_id" => job_id,
                     "video_id" => video_id,
                     "result" => "ok",
                     "chosen_crf" => 28
                   }),
                   :ok,
                   %{accepted: true, event: "crf_search_completed"}

      assert Media.get_video(video_id).state == :crf_searched
      assert Media.get_video(video_id).chosen_vmaf_id != nil
      assert WorkerSessions.get(socket.assigns.worker_id).active_video_id == nil

      assert_reply push(socket, "crf_search_completed", %{
                     "job_id" => job_id,
                     "video_id" => video_id,
                     "result" => "ok",
                     "chosen_crf" => 28
                   }),
                   :ok,
                   %{accepted: true, event: "crf_search_completed"}

      assert_reply push(socket, "pull_work", %{}),
                   :ok,
                   %{status: "no_work"}

      assert_reply push(socket, "crf_search_result", %{
                     "job_id" => job_id,
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
                   %{status: "job_assigned", video_id: ^video_id, job_id: job_id}

      assert_reply push(socket, "crf_search_result", %{
                     "job_id" => job_id,
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
                     "job_id" => job_id,
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
                   %{status: "job_assigned", video_id: ^video_id, job_id: job_id}

      assert_reply push(socket, "crf_search_completed", %{
                     "job_id" => job_id,
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
                   %{status: "job_assigned", video_id: ^video_id, job_id: job_id}

      assert_reply push(socket, "crf_search_result", %{
                     "job_id" => job_id,
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
                     "job_id" => job_id,
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

    test "accepts a legacy CRF result after the worker session is rebuilt" do
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

      assert_reply push(socket, "announce", announce_payload(worker_id: "worker-a")), :ok

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
                   %{status: "job_assigned", video_id: ^video_id, job_id: job_id}

      assert_reply push(socket, "video_failed", %{
                     "job_id" => job_id,
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

      assert [
               %{
                 failure_stage: :crf_search,
                 failure_category: :resource_exhaustion,
                 failure_code: "EXIT_137"
               }
             ] = Media.get_video_failures(video_id)

      {:ok, old_worker_video} = Fixtures.video_fixture(%{state: :analyzed})
      old_worker_video_id = old_worker_video.id

      assert {:ok, old_worker_socket} = connect(WorkerSocket, %{"token" => token})

      assert {:ok, _join_payload, old_worker_socket} =
               subscribe_and_join(old_worker_socket, "workers:crf_search")

      assert_reply push(old_worker_socket, "announce", announce_payload(worker_id: "worker-old")),
                   :ok,
                   %{accepted: true, protocol_version: 1}

      assert_reply push(old_worker_socket, "pull_work", %{}),
                   :ok,
                   %{
                     status: "job_assigned",
                     video_id: ^old_worker_video_id,
                     job_id: old_job_id
                   }

      assert_reply push(old_worker_socket, "video_failed", %{
                     "job_id" => old_job_id,
                     "video_id" => old_worker_video_id,
                     "stage" => "crf_search",
                     "category" => "process_failure",
                     "message" => "ab-av1 failed",
                     "code" => "worker_crf_search_failed",
                     "context" => %{}
                   }),
                   :ok,
                   %{accepted: true, event: "video_failed"}

      assert [
               %{
                 failure_stage: :crf_search,
                 failure_category: :process_failure,
                 failure_code: "EXIT_1"
               }
             ] = Media.get_video_failures(old_worker_video_id)

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
                   %{
                     status: "job_assigned",
                     video_id: ^cancelled_video_id,
                     job_id: cancelled_job_id
                   }

      assert_reply push(cancel_socket, "crf_search_completed", %{
                     "job_id" => cancelled_job_id,
                     "video_id" => cancelled_video_id,
                     "result" => "cancelled"
                   }),
                   :ok,
                   %{accepted: true, event: "crf_search_completed"}

      assert_receive {:crf_search_completed, %{video_id: ^cancelled_video_id, result: :cancelled}}

      assert Media.get_video(cancelled_video_id).state == :analyzed

      assert_reply push(cancel_socket, "crf_search_completed", %{
                     "job_id" => cancelled_job_id,
                     "video_id" => cancelled_video_id,
                     "result" => "cancelled"
                   }),
                   :ok,
                   %{accepted: true, event: "crf_search_completed"}
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
      assert [%{active_video_id: active_video_id}] = WorkerSessions.list()
      assert active_video_id == video.id
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

  defp report_disk_capacity(socket) do
    assert_reply push(socket, "heartbeat", %{"disk_free_bytes" => 100_000_000_000}),
                 :ok,
                 %{accepted: true}
  end

  defp track_video_lookups do
    test_pid = self()
    :meck.new(Media, [:passthrough])

    :meck.expect(Media, :get_video, fn video_id ->
      send(test_pid, {:media_get_video, video_id})
      :meck.passthrough([video_id])
    end)

    on_exit(fn -> :meck.unload() end)
  end
end
