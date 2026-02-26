defmodule Reencodarr.Media.VmafUpsertConflictTest do
  @moduledoc """
  Tests for VMAF upsert conflict handling on (crf, video_id) composite key.

  Verifies that re-upserting a VMAF with the same CRF updates rather than
  duplicates, and documents the chosen-status replacement behavior.
  """
  use Reencodarr.DataCase, async: true

  alias Reencodarr.Media

  setup do
    {:ok, video} =
      Fixtures.video_fixture(%{
        path: "/test/upsert_conflict.mkv",
        size: 1_000_000_000,
        bitrate: 5000,
        state: :analyzed,
        video_codecs: ["h264"],
        audio_codecs: ["aac"],
        max_audio_channels: 6,
        atmos: false
      })

    %{video: video}
  end

  describe "upsert_vmaf/1 conflict on (crf, video_id)" do
    test "updates existing record instead of creating a duplicate", %{video: video} do
      attrs = %{
        "video_id" => video.id,
        "crf" => "23.0",
        "score" => "95.0",
        "percent" => "50.0",
        "params" => ["--preset", "4"],
        "chosen" => false,
        "target" => 95
      }

      {:ok, first} = Media.upsert_vmaf(attrs)

      # Re-upsert same CRF with updated score
      {:ok, second} = Media.upsert_vmaf(%{attrs | "score" => "96.0"})

      # Same record, not a duplicate
      assert first.id == second.id
      assert second.score == 96.0
    end

    test "different CRFs create separate records", %{video: video} do
      base = %{
        "video_id" => video.id,
        "score" => "95.0",
        "percent" => "50.0",
        "params" => ["--preset", "4"],
        "chosen" => false,
        "target" => 95
      }

      {:ok, vmaf_23} = Media.upsert_vmaf(Map.put(base, "crf", "23.0"))
      {:ok, vmaf_25} = Media.upsert_vmaf(Map.put(base, "crf", "25.0"))

      refute vmaf_23.id == vmaf_25.id
    end

    test "re-upsert replaces chosen status", %{video: video} do
      # First upsert with chosen: false
      attrs = %{
        "video_id" => video.id,
        "crf" => "23.0",
        "score" => "95.0",
        "percent" => "50.0",
        "params" => ["--preset", "4"],
        "chosen" => false,
        "target" => 95
      }

      {:ok, _} = Media.upsert_vmaf(attrs)

      # Mark it as chosen via a second upsert
      {:ok, chosen} = Media.upsert_vmaf(%{attrs | "chosen" => true})
      assert chosen.chosen == true

      # Re-upsert with chosen: false (e.g., retry path) replaces chosen
      {:ok, unchosen} = Media.upsert_vmaf(%{attrs | "score" => "94.0"})
      assert unchosen.chosen == false
    end

    test "re-upsert updates savings calculation", %{video: video} do
      attrs = %{
        "video_id" => video.id,
        "crf" => "23.0",
        "score" => "95.0",
        "percent" => "50.0",
        "params" => ["--preset", "4"],
        "chosen" => false,
        "target" => 95
      }

      {:ok, first} = Media.upsert_vmaf(attrs)
      assert first.savings == 500_000_000

      # Re-upsert with smaller encoded size (30% → 70% savings)
      {:ok, second} = Media.upsert_vmaf(%{attrs | "percent" => "30.0"})
      assert second.savings == 700_000_000
      assert first.id == second.id
    end
  end
end
