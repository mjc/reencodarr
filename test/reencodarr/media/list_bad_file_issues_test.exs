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

  test "queue_bad_file_issue_series does not stop at the first bad-file page" do
    {:ok, series_video} =
      Fixtures.video_fixture(%{
        path: "/media/Series Queue/Season 01/series_queue_target.mkv",
        service_type: :sonarr
      })

    {:ok, issue} =
      Media.create_bad_file_issue(series_video, %{
        origin: :manual,
        issue_kind: :manual,
        classification: :manual_bad,
        manual_reason: "series queue target"
      })

    Enum.each(1..251, fn n ->
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/media/Other Series #{n}/Season 01/decoy_#{n}.mkv",
          service_type: :sonarr
        })

      {:ok, _issue} =
        Media.create_bad_file_issue(video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "series queue decoy"
        })
    end)

    assert {:ok, 1} = Media.queue_bad_file_issue_series(issue)

    assert %{status: :queued} =
             issue.id
             |> Media.get_bad_file_issue!()
             |> Reencodarr.Repo.reload!()
  end
end
