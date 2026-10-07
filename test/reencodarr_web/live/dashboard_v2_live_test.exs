defmodule ReencodarrWeb.DashboardLiveTest do
  use ReencodarrWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Reencodarr.AbAv1.WorkerProtocol.{CrfSearchProgress, EncodeProgress}
  alias Reencodarr.AbAv1.WorkerSessions
  alias Reencodarr.AbAv1.WorkerSessions.Job
  alias Reencodarr.Media
  alias ReencodarrWeb.WorkerActivity

  setup context do
    if context[:mock_sync] do
      :meck.new(Reencodarr.Sync, [:passthrough, :no_link])
      :meck.expect(Reencodarr.Sync, :sync_episodes, fn -> :ok end)
      :meck.expect(Reencodarr.Sync, :sync_movies, fn -> :ok end)
      on_exit(fn -> :meck.unload(Reencodarr.Sync) end)
    end

    WorkerSessions.reset()
    :ok
  end

  describe "worker dashboard" do
    test "reuses loaded CRF worker data across progress updates" do
      {:ok, video} = Fixtures.video_fixture(%{state: :crf_searching})
      workers = [%{active_video_id: video.id}]

      cached = WorkerActivity.load_worker_crf_data(workers)
      Reencodarr.Repo.delete!(video)

      assert WorkerActivity.load_worker_crf_data(workers, cached) == cached
    end

    test "renders active worker encode progress", %{conn: conn} do
      previous = Application.get_env(:reencodarr, :crf_execution_mode)
      Application.put_env(:reencodarr, :crf_execution_mode, :worker)

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:reencodarr, :crf_execution_mode),
          else: Application.put_env(:reencodarr, :crf_execution_mode, previous)
      end)

      {:ok, video} = Fixtures.video_fixture(%{state: :crf_searched, path: "/media/worker.mkv"})
      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 30.0, savings: 1_610_612_736})
      video = Fixtures.choose_vmaf(video, vmaf)
      {:ok, _video} = Media.mark_as_encoding(video)

      {:ok, _session} =
        WorkerSessions.register(%{
          server_worker_id: "server-encode",
          client_worker_id: "worker-encode",
          protocol_version: 1,
          version: "0.11.4",
          capabilities: %{"crf_search" => true, "encode" => true}
        })

      {:ok, _session} =
        WorkerSessions.assign_job("server-encode", %Job{
          job_id: "encode-#{video.id}",
          job_type: :encode,
          video_id: video.id,
          phase: :encoding,
          progress: %EncodeProgress{
            job_id: "encode-#{video.id}",
            video_id: video.id,
            percent: 42.0,
            fps: 12.5,
            eta: 90,
            output_bytes: 1_000,
            output_percent: 10.0,
            throughput: "12.50 fps"
          }
        })

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#encode-worker-worker-encode", "Encode")
      assert has_element?(view, "#encode-worker-worker-encode", "worker.mkv")
      assert has_element?(view, "#encode-worker-worker-encode", "42.0%")
      assert has_element?(view, "#encode-worker-worker-encode", "12.5 fps")

      assert has_element?(
               view,
               "#encode-worker-worker-encode .job-metrics span:nth-last-child(2)",
               "VMAF 95.5"
             )

      assert has_element?(
               view,
               "#encode-worker-worker-encode .job-metrics span:last-child[data-role=estimated-savings]",
               "Est. savings 1.5 GiB"
             )

      assert {:ok, _session} =
               WorkerSessions.set_job_control_state(
                 "server-encode",
                 "encode-#{video.id}",
                 :paused
               )

      assert has_element?(view, "#encode-worker-worker-encode", "Paused")
    end

    test "does not render a restored encode before the worker reclaims it", %{conn: conn} do
      previous = Application.get_env(:reencodarr, :crf_execution_mode)
      Application.put_env(:reencodarr, :crf_execution_mode, :worker)

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:reencodarr, :crf_execution_mode),
          else: Application.put_env(:reencodarr, :crf_execution_mode, previous)
      end)

      {:ok, video} = Fixtures.video_fixture(%{state: :encoding, path: "/media/restored.mkv"})

      {:ok, _session} =
        WorkerSessions.register(%{
          server_worker_id: "server-restored",
          client_worker_id: "worker-restored",
          protocol_version: 1,
          version: "0.11.4",
          capabilities: %{"crf_search" => true, "encode" => true}
        })

      {:ok, _session} =
        WorkerSessions.assign_job("server-restored", %Job{
          job_id: "encode-restored",
          job_type: :encode,
          video_id: video.id,
          phase: :encoding,
          active: false
        })

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#worker-worker-restored", "Idle")
      refute has_element?(view, "#encode-worker-worker-restored", "restored.mkv")
    end

    test "renders job-scoped worker CRF pause state", %{conn: conn} do
      previous = Application.get_env(:reencodarr, :crf_execution_mode)
      Application.put_env(:reencodarr, :crf_execution_mode, :worker)

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:reencodarr, :crf_execution_mode),
          else: Application.put_env(:reencodarr, :crf_execution_mode, previous)
      end)

      job_id = "crf-dashboard"

      {:ok, video} =
        Fixtures.video_fixture(%{
          state: :crf_searching,
          crf_search_worker_id: "worker-crf",
          worker_attempt_id: job_id,
          worker_control_desired_state: :running,
          worker_control_acknowledged_state: :running
        })

      {:ok, _session} =
        WorkerSessions.register(%{
          server_worker_id: "server-crf",
          client_worker_id: "worker-crf",
          protocol_version: 1,
          version: "0.11.4",
          capabilities: %{"crf_search" => true, "encode" => true}
        })

      {:ok, _session} =
        WorkerSessions.assign_job("server-crf", %Job{
          job_id: job_id,
          job_type: :crf_search,
          video_id: video.id
        })

      :ok =
        WorkerSessions.set_crf_search_progress("server-crf", %CrfSearchProgress{
          job_id: job_id,
          video_id: video.id,
          percent: 42.0
        })

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#crf-worker-worker-crf", "CRF search")

      assert {:ok, _session} =
               WorkerSessions.set_job_control_state("server-crf", job_id, :paused)

      assert has_element?(view, "#crf-worker-worker-crf", "Paused")

      assert has_element?(
               view,
               ~s(#crf-worker-worker-crf button[phx-click="resume_worker_crf_search"][phx-value-job-id="#{job_id}"])
             )
    end

    test "pauses CRF work restored from progress", %{conn: conn} do
      previous = Application.get_env(:reencodarr, :crf_execution_mode)
      Application.put_env(:reencodarr, :crf_execution_mode, :worker)

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:reencodarr, :crf_execution_mode),
          else: Application.put_env(:reencodarr, :crf_execution_mode, previous)
      end)

      job_id = "crf-dashboard-control"

      {:ok, video} =
        Fixtures.video_fixture(%{
          state: :crf_searching,
          crf_search_worker_id: "worker-crf",
          worker_attempt_id: job_id,
          worker_control_desired_state: :running,
          worker_control_acknowledged_state: :running
        })

      {:ok, _session} =
        WorkerSessions.register(%{
          server_worker_id: "server-crf",
          client_worker_id: "worker-crf",
          protocol_version: 1,
          version: "0.11.4",
          capabilities: %{"crf_search" => true, "encode" => true}
        })

      :ok =
        WorkerSessions.set_crf_search_progress("server-crf", %CrfSearchProgress{
          job_id: job_id,
          video_id: video.id,
          percent: 42.0
        })

      {:ok, view, _html} = live(conn, ~p"/")

      Phoenix.PubSub.subscribe(
        Reencodarr.PubSub,
        ReencodarrWeb.WorkerChannel.worker_control_topic("server-crf")
      )

      view
      |> element(
        ~s(#crf-worker-worker-crf button[phx-click="pause_worker_crf_search"][phx-value-job-id="#{job_id}"])
      )
      |> render_click()

      assert_receive {:worker_control, :pause, ^job_id, command_id}
      assert is_binary(command_id)

      updated = Media.get_video(video.id)
      assert updated.worker_control_desired_state == :paused
      assert updated.worker_control_acknowledged_state == :running
      assert has_element?(view, "#crf-worker-worker-crf", "Awaiting ACK")
    end

    test "rejects a stale CRF control without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert render_hook(view, "pause_worker_crf_search", %{"worker-id" => "stale-worker"}) =~
               "Worker job is no longer available"

      assert Process.alive?(view.pid)
    end

    test "encoder_health_alert stalled shows error flash", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      send(
        view.pid,
        {:encoder_health_alert, %{video_path: "/tmp/video.mkv", reason: :stalled_23_hours}}
      )

      html = render(view)
      assert html =~ "Encoder may be stuck"
    end

    test "encoder_health_alert with unknown reason shows generic message", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      send(view.pid, {:encoder_health_alert, %{video_path: nil, reason: :some_other_reason}})

      html = render(view)
      assert html =~ "Encoder health alert"
    end

    @tag :mock_sync
    test "sync_sonarr event starts sync and shows flash", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      html = view |> render_click("sync_sonarr", %{})

      assert html =~ "Sonarr sync started"
    end

    @tag :mock_sync
    test "sync_radarr event starts sync and shows flash", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      html = view |> render_click("sync_radarr", %{})

      assert html =~ "Radarr sync started"
    end

    test "sync_sonarr shows error when sync already in progress", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      # Manually update the view to mark sync as in progress
      send(view.pid, {:sync_started, %{service_type: "sonarr"}})

      # Render to process the message, no sleep needed
      _html = render(view)

      html = view |> render_click("sync_sonarr", %{})

      assert html =~ "Sync already in progress"
    end

    test "unknown sync_service event shows error flash", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      html = view |> render_click("sync_unknownservice", %{})

      assert html =~ "Unknown sync service"
    end

    test "includes queue previews in the initial html response", %{conn: conn} do
      previous_refresh_enabled =
        Application.get_env(:reencodarr, :dashboard_queue_refresh_enabled)

      Application.put_env(:reencodarr, :dashboard_queue_refresh_enabled, true)

      on_exit(fn ->
        Application.put_env(
          :reencodarr,
          :dashboard_queue_refresh_enabled,
          previous_refresh_enabled
        )
      end)

      {video, vmaf} =
        Fixtures.video_with_vmaf_fixture(%{
          path: "/media/initial-queue-preview.mkv",
          state: :crf_searched
        })

      Fixtures.choose_vmaf(video, vmaf)

      html =
        conn
        |> get(~p"/")
        |> html_response(200)

      assert html =~ "initial-queue-preview.mkv"
    end

    test "shows only the worker token fingerprint when configured", %{conn: conn} do
      previous_token = Application.get_env(:reencodarr, :worker_token)
      Application.put_env(:reencodarr, :worker_token, "deploy-test-worker-token")

      on_exit(fn ->
        if previous_token do
          Application.put_env(:reencodarr, :worker_token, previous_token)
        else
          Application.delete_env(:reencodarr, :worker_token)
        end
      end)

      {:ok, _view, html} = live(conn, ~p"/workers")
      expected_fingerprint = worker_token_fingerprint("deploy-test-worker-token")

      assert html =~ "Worker WebSocket"
      refute html =~ "deploy-test-worker-token"
      assert html =~ expected_fingerprint
      assert html =~ "/workers/socket/websocket?token="
    end
  end

  defp worker_token_fingerprint(token) do
    :crypto.hash(:sha256, token)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
    |> then(&"sha256:#{&1}")
  end
end
