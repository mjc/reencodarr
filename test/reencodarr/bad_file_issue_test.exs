defmodule Reencodarr.BadFileIssueTest do
  use Reencodarr.DataCase, async: true

  alias Reencodarr.Media

  describe "create_bad_file_issue/2" do
    test "creates a manual bad-file issue with note and defaults" do
      {:ok, video} = Fixtures.video_fixture()

      assert {:ok, issue} =
               Media.create_bad_file_issue(video, %{
                 origin: :manual,
                 issue_kind: :manual,
                 classification: :manual_bad,
                 manual_reason: "corrupt replacement",
                 manual_note: "dialog drifts after 5 minutes"
               })

      assert issue.video_id == video.id
      assert issue.origin == :manual
      assert issue.issue_kind == :manual
      assert issue.classification == :manual_bad
      assert issue.manual_reason == "corrupt replacement"
      assert issue.manual_note == "dialog drifts after 5 minutes"
      assert issue.status == :open
    end

    test "creates an audit issue for audio classifications" do
      {:ok, video} = Fixtures.video_fixture()

      assert {:ok, issue} =
               Media.create_bad_file_issue(video, %{
                 origin: :audit,
                 issue_kind: :audio,
                 classification: :confirmed_bad_audio_layout,
                 source_audio_codec: "eac3",
                 source_channels: 6,
                 source_layout: "5.1(side)",
                 output_audio_codec: "opus",
                 output_channels: 6,
                 output_layout: "5.1"
               })

      assert issue.origin == :audit
      assert issue.issue_kind == :audio
      assert issue.classification == :confirmed_bad_audio_layout
      assert issue.source_layout == "5.1(side)"
      assert issue.output_layout == "5.1"
    end

    test "returns validation errors for invalid enums" do
      {:ok, video} = Fixtures.video_fixture()

      changeset =
        assert_error(
          Media.create_bad_file_issue(video, %{
            origin: :manual,
            issue_kind: :manual,
            classification: :confirmed_bad_audio_layout
          })
        )

      assert_changeset_error(changeset, :classification, "is invalid")
    end

    test "reuses the unresolved manual issue for the same video and classification" do
      {:ok, video} = Fixtures.video_fixture()

      assert {:ok, first_issue} =
               Media.create_bad_file_issue(video, %{
                 origin: :manual,
                 issue_kind: :manual,
                 classification: :manual_bad,
                 manual_reason: "first"
               })

      assert {:ok, second_issue} =
               Media.create_bad_file_issue(video, %{
                 origin: :manual,
                 issue_kind: :manual,
                 classification: :manual_bad,
                 manual_reason: "updated",
                 manual_note: "reproduces consistently"
               })

      assert first_issue.id == second_issue.id
      assert second_issue.manual_reason == "updated"
      assert second_issue.manual_note == "reproduces consistently"
      assert length(Media.list_bad_file_issues()) == 1
    end
  end

  describe "bad-file issue transitions" do
    test "enqueue, retry, dismiss, and next queued issue" do
      {:ok, video} = Fixtures.video_fixture()

      {:ok, issue} =
        Media.create_bad_file_issue(video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "bad encode"
        })

      assert {:ok, queued} = Media.enqueue_bad_file_issue(issue)
      assert queued.status == :queued
      assert Media.next_queued_bad_file_issue().id == queued.id

      assert {:ok, failed} = Media.update_bad_file_issue_status(queued, :failed)
      assert failed.status == :failed

      assert {:ok, retried} = Media.retry_bad_file_issue(failed)
      assert retried.status == :queued

      assert {:ok, dismissed} = Media.dismiss_bad_file_issue(retried)
      assert dismissed.status == :dismissed
      assert Media.next_queued_bad_file_issue() == nil
    end
  end
end
