defmodule Reencodarr.DiagnosticsFailureTest do
  use Reencodarr.DataCase, async: true

  alias Reencodarr.Diagnostics
  alias Reencodarr.Media.VideoFailure

  test "shared audio rejection persists the real classification and probe evidence" do
    {:ok, video} = Fixtures.video_fixture()

    error = %Reencodarr.Rules.Audio.ClassificationError{
      track_index: 10,
      format: "A_QUICKTIME",
      codec_id: "A_QUICKTIME",
      language: "hi",
      reason: "protected sample entry enca",
      classification: :unidentified_audio,
      probe: %{"codec_tag_string" => "enca"}
    }

    assert {:ok, failure} =
             Reencodarr.FailureTracker.record_audio_classification_failure(video, error)

    failure = Repo.get!(VideoFailure, failure.id)
    assert failure.failure_category == :codec_issues
    assert failure.failure_code == "AUDIO_CLASSIFICATION"
    assert failure.system_context["classification"] == "unidentified_audio"
    assert failure.system_context["track_index"] == 10
    assert Diagnostics.failure(failure.id) =~ "enca"
  end

  test "worker failure displays argv, stderr and the original cause" do
    report =
      report(%{
        "argv" => ["encode", "--input", "/video with spaces.mkv"],
        "stderr_excerpt" => "Invalid channel layout 2.1",
        "error_chain" => ["encode failed", "encoder rejected audio"]
      })

    assert report =~ "encode"
    assert report =~ "/video with spaces.mkv"
    assert report =~ "Invalid channel layout 2.1"
    assert report =~ "encoder rejected audio"
    refute report =~ "N/A"
  end

  test "legacy command and full output remain supported and take precedence" do
    report =
      report(%{
        "command" => "ab-av1 encode legacy.mkv",
        "full_output" => "legacy output",
        "argv" => ["wrong"],
        "stderr_excerpt" => "wrong output"
      })

    assert report =~ "ab-av1 encode legacy.mkv"
    assert report =~ "legacy output"
    refute report =~ "wrong"
  end

  test "empty legacy fields fall back to worker evidence" do
    report =
      report(%{
        "command" => nil,
        "full_output" => "",
        "argv" => ["encode"],
        "stderr_excerpt" => "worker output"
      })

    assert report =~ "worker output"
    refute report =~ "Error in failure"
  end

  defp report(context) do
    {:ok, video} = Fixtures.video_fixture()

    failure =
      %VideoFailure{}
      |> VideoFailure.changeset(%{
        video_id: video.id,
        failure_stage: :encoding,
        failure_category: :codec_issues,
        failure_message: "audio failed",
        system_context: context
      })
      |> Repo.insert!()

    Diagnostics.failure(failure.id)
  end
end
