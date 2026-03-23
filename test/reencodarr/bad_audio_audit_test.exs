defmodule Reencodarr.BadAudioAuditTest do
  use Reencodarr.DataCase, async: true

  alias Reencodarr.Media
  alias Reencodarr.Media.Video
  alias Reencodarr.Repo

  @cutoff ~U[2026-02-14 02:46:11Z]

  describe "audit_pre_fix_multichannel_opus/1" do
    test "creates a likely bad audio issue from stored multichannel opus metadata" do
      video =
        candidate_video(%{
          path: "/media/confirmed-bad.mkv",
          mediainfo: source_mediainfo("Opus", 6, "5.1")
        })

      mark_updated_at(video, ~U[2026-01-01 00:00:00Z])

      assert {:ok, summary} = Media.audit_pre_fix_multichannel_opus(before: @cutoff)

      assert summary.scanned == 1
      assert summary.issues_upserted == 1

      [issue] = Media.list_bad_file_issues()
      assert issue.video_id == video.id
      assert issue.origin == :audit
      assert issue.issue_kind == :audio
      assert issue.classification == :likely_bad_pre_commit_multichannel_opus
      assert issue.source_audio_codec == "unknown"
      assert issue.source_layout == "unknown"
      assert issue.output_audio_codec == "Opus"
      assert issue.output_layout == "5.1"
    end

    test "creates a likely issue when mediainfo is missing but db audio fields and filename show multichannel opus" do
      video = candidate_video(%{path: "/media/likely-bad-5.1.mkv"})

      mark_updated_at(video, ~U[2026-01-01 00:00:00Z])

      assert {:ok, summary} = Media.audit_pre_fix_multichannel_opus(before: @cutoff)

      assert summary.scanned == 1
      assert summary.issues_upserted == 1

      [issue] = Media.list_bad_file_issues()
      assert issue.video_id == video.id
      assert issue.classification == :likely_bad_pre_commit_multichannel_opus
      assert issue.source_audio_codec == "unknown"
      assert issue.source_layout == "unknown"
      assert issue.output_audio_codec == "A_OPUS"
      assert issue.output_layout == "5.1"
    end

    test "reruns update the existing unresolved audit issue instead of duplicating it" do
      video =
        candidate_video(%{
          path: "/media/idempotent-bad.mkv",
          mediainfo: source_mediainfo("Opus", 6, "5.1")
        })

      mark_updated_at(video, ~U[2026-01-01 00:00:00Z])

      assert {:ok, _summary} = Media.audit_pre_fix_multichannel_opus(before: @cutoff)

      [first_issue] = Media.list_bad_file_issues()

      assert {:ok, _summary} = Media.audit_pre_fix_multichannel_opus(before: @cutoff)

      [second_issue] = Media.list_bad_file_issues()
      assert first_issue.id == second_issue.id
    end

    test "includes recent multichannel opus videos too" do
      video =
        candidate_video(%{
          path: "/media/recent-opus-5.1.mkv",
          state: :analyzed,
          mediainfo: source_mediainfo("Opus", 6, "5.1")
        })

      mark_updated_at(video, ~U[2026-03-01 00:00:00Z])

      assert {:ok, summary} = Media.audit_pre_fix_multichannel_opus()

      assert summary.scanned == 1
      assert summary.issues_upserted == 1

      [issue] = Media.list_bad_file_issues()
      assert issue.video_id == video.id
      assert issue.classification == :likely_bad_pre_commit_multichannel_opus
    end
  end

  defp mark_updated_at(video, updated_at) do
    {1, _rows} =
      Repo.update_all(
        from(v in Video, where: v.id == ^video.id),
        set: [updated_at: updated_at]
      )

    Repo.get!(Video, video.id)
  end

  defp source_mediainfo(format, channels, layout) do
    %{
      "media" => %{
        "track" => [
          %{"@type" => "General", "Duration" => "7200.0"},
          %{"@type" => "Video", "Format" => "AVC", "Width" => "1920", "Height" => "1080"},
          %{
            "@type" => "Audio",
            "Format" => format,
            "CodecID" => format,
            "Channels" => Integer.to_string(channels),
            "ChannelLayout" => layout,
            "Default" => "Yes"
          }
        ]
      }
    }
  end

  defp candidate_video(attrs) do
    %Video{
      path: "/media/candidate.mkv",
      size: 2_147_483_648,
      state: :encoded,
      width: 1920,
      height: 1080,
      bitrate: 3_500_000,
      audio_codecs: ["A_OPUS"],
      video_codecs: ["h264"],
      max_audio_channels: 6,
      atmos: false,
      service_id: "412",
      service_type: :sonarr
    }
    |> Map.merge(attrs)
    |> Repo.insert!()
  end
end
