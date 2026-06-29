defmodule Reencodarr.BadFiles.StateTest do
  use Reencodarr.DataCase, async: true

  alias Reencodarr.BadFiles.State
  alias Reencodarr.Fixtures
  alias Reencodarr.Media

  test "load/1 returns the bad files page payload" do
    {:ok, video} = Fixtures.video_fixture(%{path: "/media/bad_files_state_payload.mkv"})

    {:ok, _issue} =
      Media.create_bad_file_issue(video, %{
        origin: :manual,
        issue_kind: :manual,
        classification: :manual_bad,
        manual_reason: "bad files state"
      })

    payload =
      State.load(%{
        page: 1,
        per_page: 50,
        status_filter: "all",
        service_filter: "all",
        kind_filter: "all",
        search_query: "bad_files_state_payload",
        show_resolved: false
      })

    assert Enum.any?(payload.issues, &(&1.video_id == video.id))
    assert payload.active_total >= 1
    assert is_map(payload.issue_summary)
    assert payload.tracked_count >= 1
  end

  test "resolved filter loads resolved issues even when show_resolved is false" do
    {:ok, video} = Fixtures.video_fixture(%{path: "/media/resolved_filter_payload.mkv"})

    {:ok, issue} =
      Media.create_bad_file_issue(video, %{
        origin: :manual,
        issue_kind: :manual,
        classification: :manual_bad,
        manual_reason: "resolved filter"
      })

    {:ok, _issue} = Media.dismiss_bad_file_issue(issue)

    payload =
      State.load(%{
        page: 1,
        per_page: 50,
        status_filter: "resolved",
        service_filter: "all",
        kind_filter: "all",
        search_query: "resolved_filter_payload",
        show_resolved: false
      })

    assert Enum.any?(payload.resolved_issues, &(&1.video_id == video.id))
    assert Enum.any?(payload.issues, &(&1.video_id == video.id))
  end

  test "list_active_issues returns all matching pages for bulk actions" do
    Enum.each(1..251, fn n ->
      {:ok, video} = Fixtures.video_fixture(%{path: "/media/bulk_filtered_#{n}.mkv"})

      {:ok, _issue} =
        Media.create_bad_file_issue(video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "bulk filtered"
        })
    end)

    issues =
      State.list_active_issues(%{
        page: 1,
        per_page: 50,
        status_filter: "all",
        service_filter: "all",
        kind_filter: "all",
        search_query: "bulk_filtered",
        show_resolved: false
      })

    assert Enum.count(issues) == 251
  end
end
