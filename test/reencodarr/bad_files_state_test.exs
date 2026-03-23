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
end
