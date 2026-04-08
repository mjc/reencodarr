defmodule ReencodarrWeb.DashboardLiveTest do
  @moduledoc """
  Basic tests for DashboardLive component functionality.

  Tests cover:
  - Component mounting and basic UI rendering
  - Button interactions without internal state checking
  - Event handling for service communication
  """
  use ReencodarrWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

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
        crf_progress: :none,
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
        crf_progress: :none,
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
        crf_progress: :none,
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
        crf_progress: %{video_id: 1, percent: 37.0, filename: "chart-pending.mkv"},
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
      assert html =~ "Waiting for first VMAF result..."
      assert html =~ ~s(<svg viewBox="0 0 320 140")
      assert html =~ "CRF 15"
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
end
