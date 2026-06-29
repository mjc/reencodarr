defmodule Reencodarr.Media.ListBadFileIssuesTest do
  use Reencodarr.DataCase, async: true

  alias Reencodarr.Fixtures
  alias Reencodarr.Media

  test "list_bad_file_issues/2 filters by kind and paginates" do
    {:ok, audio_video} = Fixtures.video_fixture(%{path: "/media/audio_issue.mkv"})
    {:ok, manual_video} = Fixtures.video_fixture(%{path: "/media/manual_issue.mkv"})

    {:ok, _} =
      Media.create_bad_file_issue(audio_video, %{
        origin: :manual,
        issue_kind: :audio,
        classification: :confirmed_bad_audio_layout
      })

    {:ok, _} =
      Media.create_bad_file_issue(manual_video, %{
        origin: :manual,
        issue_kind: :manual,
        classification: :manual_bad,
        manual_reason: "manual"
      })

    assert {issues, meta} =
             Media.list_bad_file_issues(%{"kind" => "audio", "page" => "1", "page_size" => "10"})

    assert meta.total_count == 1
    assert [%{issue_kind: :audio}] = issues
  end

  test "search matches video path" do
    {:ok, video} = Fixtures.video_fixture(%{path: "/media/searchable_bad.mkv"})

    {:ok, _} =
      Media.create_bad_file_issue(video, %{
        origin: :manual,
        issue_kind: :manual,
        classification: :manual_bad,
        manual_reason: "searchable"
      })

    assert {issues, meta} = Media.list_bad_file_issues(%{"search" => "searchable_bad"})
    assert meta.total_count == 1
    assert hd(issues).video.path =~ "searchable_bad"
  end
end
