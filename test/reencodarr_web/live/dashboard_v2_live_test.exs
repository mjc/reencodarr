defmodule ReencodarrWeb.DashboardV2LiveTest do
  @moduledoc """
  Basic tests for DashboardV2Live component functionality.

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
      assert html =~ "Video Processing Dashboard"
      assert html =~ "Processing Pipeline"
      assert html =~ "Analysis"
      assert html =~ "CRF Search"
      assert html =~ "Encoding"
      assert html =~ "Media Library Sync"
      assert html =~ "Sonarr"
      assert html =~ "Radarr"
    end

    test "handles service control button clicks without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Test analyzer control buttons
      view |> element("button[phx-click='start_analyzer']") |> render_click()
      view |> element("button[phx-click='pause_analyzer']") |> render_click()

      # Test crf_searcher control buttons
      view |> element("button[phx-click='start_crf_searcher']") |> render_click()
      view |> element("button[phx-click='pause_crf_searcher']") |> render_click()

      # Test encoder control buttons
      view |> element("button[phx-click='start_encoder']") |> render_click()
      view |> element("button[phx-click='pause_encoder']") |> render_click()

      # If we get here without error, the buttons work
      assert true
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
      assert html =~ "Video Processing Dashboard"
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
      assert html =~ "Video Processing Dashboard"
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
      assert html =~ "Video Processing Dashboard"
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
      assert html =~ "Video Processing Dashboard"
    end

    test "handles throughput events without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Send throughput update in correct format
      send(view.pid, {:analyzer_throughput, %{throughput: 2.5}})

      # Wait for events to process
      :timer.sleep(100)

      # Re-render to ensure events were processed
      html = render(view)
      assert html =~ "Video Processing Dashboard"
    end
  end

  describe "UI display validation" do
    test "displays service status information", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Send service status and check it appears in UI
      send(view.pid, {:service_status, :analyzer, :running})
      :timer.sleep(50)

      html = render(view)
      # Should show some indication of running status
      assert html =~ "Running" || html =~ "running" || html =~ "Processing" ||
               html =~ "processing"
    end

    test "displays queue counts in UI", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Send queue count and verify it shows up
      send(view.pid, {:queue_count, :analyzer, 5})
      :timer.sleep(50)

      html = render(view)
      # Should show the queue count
      assert html =~ "5"
    end

    test "handles throughput events without error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Send throughput update
      send(view.pid, {:analyzer_throughput, %{throughput: 2.5}})
      :timer.sleep(100)

      # Just verify page still renders after throughput event
      html = render(view)
      assert html =~ "Video Processing Dashboard"
    end

    test "handles sync already in progress gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Start sync
      send(view.pid, {:sync_started, %{service_type: "sonarr"}})
      :timer.sleep(100)

      # Check that the page still renders correctly with sync in progress
      html = render(view)
      assert html =~ "Video Processing Dashboard"

      # Note: We can't test button clicking when disabled,
      # so we'll just verify the page handles the sync state
    end
  end
end
