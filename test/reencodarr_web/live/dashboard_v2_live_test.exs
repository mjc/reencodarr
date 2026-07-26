defmodule ReencodarrWeb.DashboardLiveTest do
  @moduledoc """
  Basic tests for DashboardLive component functionality.

  Tests cover:
  - Component mounting and basic UI rendering
  - Button interactions without internal state checking
  - Event handling for service communication
  """
  use ReencodarrWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Reencodarr.AbAv1.WorkerProtocol.CrfSearchProgress
  alias Reencodarr.AbAv1.WorkerProtocol.EncodeProgress
  alias Reencodarr.AbAv1.WorkerSessions
  alias Reencodarr.AbAv1.WorkerSessions.Job
  alias Reencodarr.Media
  alias ReencodarrWeb.CrfSearchComponents

  setup do
    WorkerSessions.reset()
    :ok
  end

  describe "basic functionality" do
    test "mounts successfully and displays initial state", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      # Check page loaded successfully
      assert html =~ "Reencodarr"
      assert html =~ "Processing Pipeline"
      assert html =~ "Analysis"
      assert html =~ "CRF Search"
      assert html =~ "Encoding"
      assert html =~ "Media Library Sync"
      assert html =~ "Sonarr"
      assert html =~ "Radarr"
      assert html =~ "Open workers"
      assert html =~ "CRF: broadway"
      assert html =~ "disabled (Broadway active)"
      assert html =~ ~s(id="dashboard-root")
      assert html =~ ~s(phx-hook="DashboardAnimations")
      assert html =~ ~s(id="dashboard-active-work")
      assert html =~ ~s(id="broadway-crf-search-panel")
      assert html =~ "Needs Analysis:"
      assert html =~ "VMAF Score Distribution"
    end

    test "renders one CRF search and encoding panel per worker in worker mode", %{conn: conn} do
      previous = Application.get_env(:reencodarr, :crf_execution_mode)
      Application.put_env(:reencodarr, :crf_execution_mode, :worker)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:reencodarr, :crf_execution_mode)
        else
          Application.put_env(:reencodarr, :crf_execution_mode, previous)
        end
      end)

      for suffix <- ["one", "two"] do
        assert {:ok, _session} =
                 WorkerSessions.register(%{
                   server_worker_id: "server-#{suffix}",
                   client_worker_id: "worker-#{suffix}",
                   protocol_version: 1,
                   version: "0.11.4",
                   capabilities: %{"crf_search" => true, "encode" => true}
                 })
      end

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#crf-worker-server-one", "CRF Search · worker-one")
      assert has_element?(view, "#crf-worker-server-two", "CRF Search · worker-two")
      assert has_element?(view, "#encode-worker-server-one", "Encoding · worker-one")
      assert has_element?(view, "#encode-worker-server-two", "Encoding · worker-two")
      refute has_element?(view, "#broadway-crf-search-panel")
      refute has_element?(view, "#broadway-encoding-panel")
      refute has_element?(view, "#no-crf-workers")
    end

    test "reuses loaded CRF worker data across progress updates" do
      {:ok, video} = Fixtures.video_fixture(%{state: :crf_searching})
      workers = [%{active_video_id: video.id}]

      cached = CrfSearchComponents.load_worker_crf_data(workers)
      Reencodarr.Repo.delete!(video)

      assert CrfSearchComponents.load_worker_crf_data(workers, cached) == cached
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
      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 30.0})
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

      assert has_element?(view, "#encode-worker-server-encode", "Encoding · worker-encode")
      assert has_element?(view, "#encode-worker-server-encode", "worker.mkv")
      assert has_element?(view, "#encode-worker-server-encode", "42.0%")
      assert has_element?(view, "#encode-worker-server-encode", "12.5 fps")

      assert {:ok, _session} =
               WorkerSessions.set_job_control_state(
                 "server-encode",
                 "encode-#{video.id}",
                 :paused
               )

      assert has_element?(view, "#encode-worker-server-encode", "Paused")
    end

    test "renders job-scoped worker CRF pause state", %{conn: conn} do
      previous = Application.get_env(:reencodarr, :crf_execution_mode)
      Application.put_env(:reencodarr, :crf_execution_mode, :worker)

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:reencodarr, :crf_execution_mode),
          else: Application.put_env(:reencodarr, :crf_execution_mode, previous)
      end)

      {:ok, video} = Fixtures.video_fixture(%{state: :crf_searching})
      job_id = Integer.to_string(video.id)

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

      {:ok, _session} =
        WorkerSessions.set_crf_search_progress("server-crf", %CrfSearchProgress{
          job_id: job_id,
          video_id: video.id,
          percent: 42.0
        })

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#crf-worker-server-crf", "Processing")

      assert {:ok, _session} =
               WorkerSessions.set_job_control_state("server-crf", job_id, :paused)

      assert has_element?(view, "#crf-worker-server-crf", "Paused")

      assert has_element?(
               view,
               ~s(#crf-worker-server-crf button[phx-click="resume_worker_crf_search"][phx-value-job-id="#{job_id}"])
             )
    end

    test "renders worker CRF progress structs" do
      html =
        render_component(&CrfSearchComponents.crf_search_panel/1,
          video: %{
            filename: "worker-progress.mkv",
            video_size: 1_000,
            width: 1920,
            height: 1080,
            hdr: nil,
            target_vmaf: 95
          },
          results: [],
          sample: nil,
          progress: %CrfSearchProgress{video_id: 1, percent: 62.0, fps: 12.5, eta: 90},
          status: :processing
        )

      assert html =~ "62.0%"
      assert html =~ "12.5 fps"
      assert html =~ "ETA: 90"
    end

    test "shows worker execution mode without calling stopped Broadway a worker failure", %{
      conn: conn
    } do
      previous = Application.get_env(:reencodarr, :crf_execution_mode)
      Application.put_env(:reencodarr, :crf_execution_mode, :worker)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:reencodarr, :crf_execution_mode)
        else
          Application.put_env(:reencodarr, :crf_execution_mode, previous)
        end
      end)

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "CRF: worker"
      assert html =~ "Local worker process"
      assert html =~ "no workers connected"
    end

    @tag :expected_failure
    test "service control button clicks crash when Broadway services unavailable", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Test that Broadway service buttons crash when services aren't available in test environment
      # This verifies our event handlers are correctly calling Broadway producers
      # The test is expected to fail with EXIT because Broadway processes aren't running

      # This will crash because Broadway.CrfSearcher isn't available in tests (expected behavior)
      view |> element("button[phx-click='start_crf_searcher']") |> render_click()

      # If we reach here, something is wrong - Broadway should have crashed
      flunk("Expected Broadway service to crash when unavailable")
    end

    test "sync buttons exist in UI", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      # Test sync buttons are present
      assert html =~ "phx-click=\"sync_sonarr\""
      assert html =~ "phx-click=\"sync_radarr\""

      # If we get here, the buttons are present in the template
      assert true
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

      {:ok, _video} =
        Fixtures.video_fixture(%{path: "/media/initial-queue-preview.mkv", state: :analyzed})

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

      {:ok, _view, html} = live(conn, ~p"/")
      expected_fingerprint = worker_token_fingerprint("deploy-test-worker-token")

      assert html =~ "Worker WebSocket"
      refute html =~ "deploy-test-worker-token"
      assert html =~ expected_fingerprint
      assert html =~ "/workers/socket/websocket?token="
    end

    test "includes chart data in the initial html response", %{conn: conn} do
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/media/initial-chart-preview.mkv",
          state: :crf_searched,
          width: 1920,
          height: 1080,
          video_codecs: ["AV1"]
        })

      vmaf = Fixtures.vmaf_fixture(%{video_id: video.id, score: 95.1, crf: 24.0})
      Fixtures.choose_vmaf(video, vmaf)

      html =
        conn
        |> get(~p"/")
        |> html_response(200)

      assert html =~ "AV1"
      assert html =~ "1080p"
      assert html =~ "94-96"
    end
  end

  describe "event handling" do
    test "handles service status events without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Send various service status events
      send(view.pid, {:service_status, :analyzer, :running})
      send(view.pid, {:service_status, :crf_searcher, :processing})
      send(view.pid, {:service_status, :encoder, :idle})

      # Wait for events to process
      :timer.sleep(100)

      # Re-render to ensure events were processed
      html = render(view)
      assert html =~ "Processing Pipeline"
    end

    test "handles queue count events without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Send queue count updates
      send(view.pid, {:queue_count, :analyzer, 5})
      send(view.pid, {:queue_count, :crf_searcher, 3})
      send(view.pid, {:queue_count, :encoder, 2})

      # Wait for events to process
      :timer.sleep(100)

      # Re-render to ensure events were processed
      html = render(view)
      assert html =~ "Processing Pipeline"
    end

    test "handles progress events without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Send various progress events
      send(view.pid, {:analyzer_progress, %{percent: 75}})
      send(view.pid, {:crf_progress, %{filename: "test.mkv", crf: 25, score: 95.2, percent: 80}})

      send(
        view.pid,
        {:encoding_progress, %{filename: "movie.mkv", fps: 30, eta: 120, percent: 45}}
      )

      # Wait for events to process
      :timer.sleep(100)

      # Re-render to ensure events were processed
      html = render(view)
      assert html =~ "Processing Pipeline"
    end

    test "handles sync events without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Send sync events with correct format
      send(view.pid, {:sync_started, %{service_type: "sonarr"}})
      send(view.pid, {:sync_progress, %{progress: 50}})
      send(view.pid, {:sync_completed, %{message: "Success"}})

      # Wait for events to process
      :timer.sleep(100)

      # Re-render to ensure events were processed
      html = render(view)
      assert html =~ "Processing Pipeline"
    end

    test "handles throughput events without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Send throughput update in correct format
      send(view.pid, {:analyzer_throughput, %{throughput: 2.5}})

      # Wait for events to process
      :timer.sleep(100)

      # Re-render to ensure events were processed
      html = render(view)
      assert html =~ "Processing Pipeline"
    end
  end

  describe "UI display validation" do
    test "displays service status information", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Construct dashboard state with running analyzer
      state = %{
        crf_search_video: nil,
        crf_search_results: [],
        crf_search_sample: nil,
        crf_progress: nil,
        encoding_video: nil,
        encoding_vmaf: nil,
        encoding_progress: :none,
        service_status: %{analyzer: :running, crf_searcher: :idle, encoder: :idle},
        stats: Reencodarr.Media.get_default_stats(),
        queue_counts: %{analyzer: 0, crf_searcher: 0, encoder: 0},
        queue_items: %{analyzer: [], crf_searcher: [], encoder: []},
        vmaf_distribution: [],
        resolution_distribution: [],
        codec_distribution: []
      }

      send(view.pid, {:dashboard_state_changed, state})
      :timer.sleep(50)

      html = render(view)
      # Should show some indication of running status
      assert html =~ "Running" || html =~ "running" || html =~ "Processing" ||
               html =~ "processing"
    end

    test "displays queue counts in UI", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Construct dashboard state with queue counts
      state = %{
        crf_search_video: nil,
        crf_search_results: [],
        crf_search_sample: nil,
        crf_progress: nil,
        encoding_video: nil,
        encoding_vmaf: nil,
        encoding_progress: :none,
        service_status: %{analyzer: :idle, crf_searcher: :idle, encoder: :idle},
        stats: Reencodarr.Media.get_default_stats(),
        queue_counts: %{analyzer: 5, crf_searcher: 0, encoder: 0},
        queue_items: %{analyzer: [], crf_searcher: [], encoder: []},
        vmaf_distribution: [],
        resolution_distribution: [],
        codec_distribution: []
      }

      send(view.pid, {:dashboard_state_changed, state})
      :timer.sleep(50)

      html = render(view)
      # Should show the queue count
      assert html =~ "5"
    end

    test "renders CRF search chart when active search results are present", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      state = %{
        crf_search_video: %{
          video_id: 1,
          filename: "chart-test.mkv",
          target_vmaf: 95,
          video_size: 1_000_000_000,
          width: 1920,
          height: 1080,
          hdr: "HDR10"
        },
        crf_search_results: [
          %{crf: 24, score: 97.1, percent: 96.0},
          %{crf: 28, score: 94.8, percent: 93.5}
        ],
        crf_search_sample: %{crf: 26, sample_num: 1, total_samples: 3},
        crf_progress: nil,
        encoding_video: nil,
        encoding_vmaf: nil,
        encoding_progress: :none,
        service_status: %{analyzer: :idle, crf_searcher: :processing, encoder: :idle},
        stats: Reencodarr.Media.get_default_stats(),
        queue_counts: %{analyzer: 0, crf_searcher: 2, encoder: 0},
        queue_items: %{analyzer: [], crf_searcher: [], encoder: []},
        vmaf_distribution: [],
        resolution_distribution: [],
        codec_distribution: []
      }

      send(view.pid, {:dashboard_state_changed, state})
      :timer.sleep(50)

      html = render(view)
      assert html =~ "chart-test.mkv"
      assert html =~ "Target: 95 VMAF"
      assert html =~ "CRF 24"
      assert html =~ "CRF 28"
      assert html =~ ~s(<svg viewBox="0 0 320 140")
    end

    test "active job controls use pause, resume, and stop labels", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      active_state = %{
        crf_search_video: %{
          video_id: 1,
          filename: "controls-test.mkv",
          target_vmaf: 95,
          video_size: 1_000_000_000,
          width: 1920,
          height: 1080,
          hdr: nil
        },
        crf_search_results: [],
        crf_search_sample: nil,
        crf_progress: nil,
        encoding_video: nil,
        encoding_vmaf: nil,
        encoding_progress: :none,
        service_status: %{analyzer: :idle, crf_searcher: :processing, encoder: :idle},
        stats: Reencodarr.Media.get_default_stats(),
        queue_counts: %{analyzer: 0, crf_searcher: 0, encoder: 0},
        queue_items: %{analyzer: [], crf_searcher: [], encoder: []},
        vmaf_distribution: [],
        resolution_distribution: [],
        codec_distribution: []
      }

      send(view.pid, {:dashboard_state_changed, active_state})
      :timer.sleep(50)

      html = render(view)
      assert html =~ "Pause"
      assert html =~ "Stop"
      refute html =~ ">Fail<"
      refute html =~ "Suspend"

      send(
        view.pid,
        {:dashboard_state_changed,
         %{
           active_state
           | service_status: %{analyzer: :idle, crf_searcher: :paused, encoder: :idle}
         }}
      )

      :timer.sleep(50)

      html = render(view)
      assert html =~ "Resume"
      assert html =~ "Stop"
    end

    test "renders CRF search chart before first result when sample is active", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      state = %{
        crf_search_video: %{
          video_id: 1,
          filename: "chart-pending.mkv",
          target_vmaf: 95,
          video_size: 1_000_000_000,
          width: 1920,
          height: 1080,
          hdr: "HDR10"
        },
        crf_search_results: [],
        crf_search_sample: %{crf: 15.0, sample_num: 6, total_samples: 8},
        crf_progress: %CrfSearchProgress{
          video_id: 1,
          percent: 37.0,
          filename: "chart-pending.mkv"
        },
        encoding_video: nil,
        encoding_vmaf: nil,
        encoding_progress: :none,
        service_status: %{analyzer: :idle, crf_searcher: :processing, encoder: :idle},
        stats: Reencodarr.Media.get_default_stats(),
        queue_counts: %{analyzer: 0, crf_searcher: 2, encoder: 0},
        queue_items: %{analyzer: [], crf_searcher: [], encoder: []},
        vmaf_distribution: [],
        resolution_distribution: [],
        codec_distribution: []
      }

      send(view.pid, {:dashboard_state_changed, state})
      :timer.sleep(50)

      html = render(view)
      assert html =~ "chart-pending.mkv"
      assert html =~ "Sample 6/8"
      assert html =~ "Sampling CRF 15"
      assert html =~ "waiting for first completed VMAF result"
      assert html =~ ~s(<svg viewBox="0 0 320 140")
      assert html =~ "CRF 15"
    end

    test "renders Broadway progress without optional fps or eta", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      send(view.pid, {
        :dashboard_state_changed,
        %{
          crf_search_video: %{
            video_id: 1,
            filename: "partial-progress.mkv",
            target_vmaf: 95,
            video_size: 1_000,
            width: 1920,
            height: 1080,
            hdr: nil
          },
          crf_search_results: [],
          crf_search_sample: nil,
          crf_progress: %CrfSearchProgress{
            video_id: 1,
            percent: 37.0,
            filename: "partial-progress.mkv"
          },
          encoding_video: nil,
          encoding_vmaf: nil,
          encoding_progress: :none,
          service_status: %{analyzer: :idle, crf_searcher: :processing, encoder: :idle},
          stats: Reencodarr.Media.get_default_stats(),
          queue_counts: %{analyzer: 0, crf_searcher: 0, encoder: 0},
          queue_items: %{analyzer: [], crf_searcher: [], encoder: []},
          vmaf_distribution: [],
          resolution_distribution: [],
          codec_distribution: []
        }
      })

      :timer.sleep(50)
      assert render(view) =~ "37.0%"
    end

    test "handles throughput events without error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Send throughput update
      send(view.pid, {:analyzer_throughput, %{throughput: 2.5}})
      :timer.sleep(100)

      # Just verify page still renders after throughput event
      html = render(view)
      assert html =~ "Processing Pipeline"
    end

    test "handles sync already in progress gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Start sync
      send(view.pid, {:sync_started, %{service_type: "sonarr"}})
      :timer.sleep(100)

      # Check that the page still renders correctly with sync in progress
      html = render(view)
      assert html =~ "Processing Pipeline"

      # Note: We can't test button clicking when disabled,
      # so we'll just verify the page handles the sync state
    end

    test "handles batch_analysis_completed event without crashing", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      send(view.pid, {:batch_analysis_completed, %{batch_size: 5}})
      :timer.sleep(50)

      assert render(view) =~ "Processing Pipeline"
    end

    test "handles analyzer_progress event without crashing", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      send(view.pid, {:analyzer_progress, %{current: 3, total: 10, batch_size: 2}})
      :timer.sleep(50)

      assert render(view) =~ "Processing Pipeline"
    end

    test "encoder_health_alert stalled shows error flash", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      send(
        view.pid,
        {:encoder_health_alert, %{video_path: "/tmp/video.mkv", reason: :stalled_23_hours}}
      )

      :timer.sleep(50)

      html = render(view)
      assert html =~ "Encoder may be stuck"
    end

    test "encoder_health_alert with unknown reason shows generic message", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      send(view.pid, {:encoder_health_alert, %{video_path: nil, reason: :some_other_reason}})
      :timer.sleep(50)

      html = render(view)
      assert html =~ "Encoder health alert"
    end
  end

  describe "sync event handlers" do
    test "sync_sonarr event starts sync and shows flash", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/")

      html = view |> render_click("sync_sonarr", %{})

      assert html =~ "Sonarr sync started"
    end

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
  end

  defp worker_token_fingerprint(token) do
    :crypto.hash(:sha256, token)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
    |> then(&"sha256:#{&1}")
  end
end
