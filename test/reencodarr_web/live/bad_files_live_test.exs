defmodule ReencodarrWeb.BadFilesLiveTest do
  use ReencodarrWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Reencodarr.Fixtures
  alias Reencodarr.Media

  describe "mount" do
    test "renders the bad files page with listed issues", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/bad_queue.mkv"})

      {:ok, _issue} =
        Media.create_bad_file_issue(video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "wrong release group",
          manual_note: "known bad import"
        })

      {:ok, _view, html} = live(conn, ~p"/bad-files")

      assert html =~ "Bad Files"
      assert html =~ "wrong release group"
      assert html =~ "bad_queue.mkv"
    end
  end

  describe "issue actions" do
    test "enqueue updates status to queued", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/enqueue_bad.mkv"})

      {:ok, issue} =
        Media.create_bad_file_issue(video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "bad mux"
        })

      {:ok, view, _html} = live(conn, ~p"/bad-files")
      html = view |> element("#enqueue-issue-#{issue.id}") |> render_click()

      assert html =~ "Queued bad-file issue"
      assert Media.get_bad_file_issue!(issue.id).status == :queued
    end

    test "dismiss updates status to dismissed", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/dismiss_bad.mkv"})

      {:ok, issue} =
        Media.create_bad_file_issue(video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "damaged rip"
        })

      {:ok, view, _html} = live(conn, ~p"/bad-files")
      html = view |> element("#dismiss-issue-#{issue.id}") |> render_click()

      assert html =~ "Dismissed bad-file issue"
      assert Media.get_bad_file_issue!(issue.id).status == :dismissed
    end

    test "retry moves failed issues back to queued", %{conn: conn} do
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/retry_bad.mkv"})

      {:ok, issue} =
        Media.create_bad_file_issue(video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "still bad"
        })

      {:ok, failed_issue} = Media.update_bad_file_issue_status(issue, :failed)

      {:ok, view, _html} = live(conn, ~p"/bad-files")
      html = view |> element("#retry-issue-#{failed_issue.id}") |> render_click()

      assert html =~ "Re-queued bad-file issue"
      assert Media.get_bad_file_issue!(failed_issue.id).status == :queued
    end
  end
end
