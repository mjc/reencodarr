defmodule Reencodarr.Media.MarkVmafAsChosenTest do
  @moduledoc """
  Tests for mark_vmaf_as_chosen/2 return value semantics.
  Verifies that marking a nonexistent CRF returns an error
  rather than silently succeeding.
  """
  use Reencodarr.DataCase, async: true

  alias Reencodarr.Media

  setup do
    {:ok, video} =
      Fixtures.video_fixture(%{
        path: "/test/mark_chosen.mkv",
        size: 1_000_000_000,
        bitrate: 5000,
        state: :crf_searching,
        video_codecs: ["h264"],
        audio_codecs: ["aac"],
        max_audio_channels: 6,
        atmos: false
      })

    # Insert a VMAF at CRF 23.0
    {:ok, _vmaf} =
      Media.upsert_vmaf(%{
        "video_id" => video.id,
        "crf" => "23.0",
        "score" => "95.0",
        "percent" => "50.0",
        "params" => ["--preset", "4"],
        "target" => 95
      })

    %{video: video}
  end

  describe "mark_vmaf_as_chosen/2" do
    test "returns :ok when CRF matches an existing VMAF", %{video: video} do
      assert {:ok, _} = Media.mark_vmaf_as_chosen(video.id, "23.0")

      updated_video = Media.get_video(video.id)
      [vmaf] = Media.get_vmafs_for_video(video.id)
      assert updated_video.chosen_vmaf_id == vmaf.id
    end

    test "returns error when CRF does not match any VMAF", %{video: video} do
      result = Media.mark_vmaf_as_chosen(video.id, "99.0")

      assert {:error, :no_vmaf_matched} = result

      # Video should have no chosen VMAF
      updated_video = Media.get_video(video.id)
      assert is_nil(updated_video.chosen_vmaf_id)
    end

    test "returns error for invalid CRF string", %{video: video} do
      assert {:error, :invalid_crf} = Media.mark_vmaf_as_chosen(video.id, "not_a_number")
    end
  end
end
