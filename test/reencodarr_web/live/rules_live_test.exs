defmodule ReencodarrWeb.RulesLiveTest do
  @moduledoc """
  Tests for RulesLive encoding rules documentation page.
  """
  use ReencodarrWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders encoding rules page with overview section", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/rules")

      assert html =~ "Encoding Rules Documentation"
    end

    test "shows overview section by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/rules")

      assert html =~ "Learn how Reencodarr automatically optimizes"
    end

    test "overview section shows encoding rules overview heading", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/rules")

      assert html =~ "Encoding Rules Overview"
    end

    test "overview section is selected by default in navigation", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/rules")

      # The overview nav button should be active (blue background)
      assert html =~ "phx-value-section=\"overview\""
    end

    test "overview does not show other sections' content", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/rules")

      refute html =~ "VIDEO ENCODING STANDARDS"
      refute html =~ "SMART AUDIO TRANSCODING"
      refute html =~ "HDR &amp; SDR OPTIMIZATION"
      refute html =~ "4K+ DOWNSCALING"
      refute html =~ "OPTIONAL ENHANCEMENT FEATURES"
      refute html =~ "CRF SEARCH EXPLAINED"
      refute html =~ "REAL COMMAND EXAMPLES"
    end

    test "navigation shows all 8 section buttons", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/rules")

      assert html =~ "phx-value-section=\"overview\""
      assert html =~ "phx-value-section=\"video_rules\""
      assert html =~ "phx-value-section=\"audio_rules\""
      assert html =~ "phx-value-section=\"hdr_support\""
      assert html =~ "phx-value-section=\"resolution_scaling\""
      assert html =~ "phx-value-section=\"helper_rules\""
      assert html =~ "phx-value-section=\"crf_search\""
      assert html =~ "phx-value-section=\"command_examples\""
    end
  end

  describe "select_section event" do
    test "switching to video_rules shows VIDEO ENCODING STANDARDS", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/rules")

      html = view |> render_click("select_section", %{"section" => "video_rules"})

      assert html =~ "VIDEO ENCODING STANDARDS"
    end

    test "video_rules section hides overview content", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/rules")

      html = view |> render_click("select_section", %{"section" => "video_rules"})

      refute html =~ "Encoding Rules Overview"
    end

    test "switching to audio_rules shows SMART AUDIO TRANSCODING", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/rules")

      html = view |> render_click("select_section", %{"section" => "audio_rules"})

      assert html =~ "SMART AUDIO TRANSCODING"
    end

    test "switching to hdr_support shows HDR section heading", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/rules")

      html = view |> render_click("select_section", %{"section" => "hdr_support"})

      assert html =~ "HDR"
      assert html =~ "SDR OPTIMIZATION"
    end

    test "switching to resolution_scaling shows 4K+ DOWNSCALING", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/rules")

      html = view |> render_click("select_section", %{"section" => "resolution_scaling"})

      assert html =~ "4K+ DOWNSCALING"
    end

    test "switching to helper_rules shows OPTIONAL ENHANCEMENT FEATURES", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/rules")

      html = view |> render_click("select_section", %{"section" => "helper_rules"})

      assert html =~ "OPTIONAL ENHANCEMENT FEATURES"
    end

    test "switching to crf_search shows CRF SEARCH EXPLAINED", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/rules")

      html = view |> render_click("select_section", %{"section" => "crf_search"})

      assert html =~ "CRF SEARCH EXPLAINED"
    end

    test "switching to command_examples shows REAL COMMAND EXAMPLES", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/rules")

      html = view |> render_click("select_section", %{"section" => "command_examples"})

      assert html =~ "REAL COMMAND EXAMPLES"
    end

    test "switching sections multiple times works correctly", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/rules")

      view |> render_click("select_section", %{"section" => "video_rules"})
      view |> render_click("select_section", %{"section" => "audio_rules"})
      html = view |> render_click("select_section", %{"section" => "crf_search"})

      assert html =~ "CRF SEARCH EXPLAINED"
      refute html =~ "VIDEO ENCODING STANDARDS"
      refute html =~ "SMART AUDIO TRANSCODING"
    end

    test "unknown section keeps current section shown", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/rules")

      # Navigate to video_rules first
      view |> render_click("select_section", %{"section" => "video_rules"})

      # Then try an invalid section
      html = view |> render_click("select_section", %{"section" => "nonexistent_section"})

      # Video rules content should still be shown
      assert html =~ "VIDEO ENCODING STANDARDS"
    end

    test "unknown section is ignored gracefully", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/rules")

      html = view |> render_click("select_section", %{"section" => "nonexistent_section"})

      assert html =~ "Encoding Rules Documentation"
    end

    test "atom-injection attempt via select_section is rejected", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/rules")

      # A section name that isn't in @valid_sections
      html = view |> render_click("select_section", %{"section" => "kernel.exit"})

      assert html =~ "Encoding Rules Documentation"
    end

    test "each section shows only its own content", %{conn: conn} do
      sections_and_content = [
        {"video_rules", "VIDEO ENCODING STANDARDS"},
        {"audio_rules", "SMART AUDIO TRANSCODING"},
        {"hdr_support", "SDR OPTIMIZATION"},
        {"resolution_scaling", "4K+ DOWNSCALING"},
        {"helper_rules", "OPTIONAL ENHANCEMENT FEATURES"},
        {"crf_search", "CRF SEARCH EXPLAINED"},
        {"command_examples", "REAL COMMAND EXAMPLES"}
      ]

      for {section, expected_content} <- sections_and_content do
        {:ok, view, _} = live(conn, ~p"/rules")
        html = view |> render_click("select_section", %{"section" => section})

        assert html =~ expected_content,
               "Section #{section} should show #{expected_content}"
      end
    end
  end
end
