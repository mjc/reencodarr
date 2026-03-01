defmodule Reencodarr.Media.ChooseBestVmafTest do
  @moduledoc """
  Tests for Media.choose_best_vmaf/1 - auto-selecting the best VMAF
  when no VMAF was explicitly marked as chosen (e.g. success line not parsed).
  """
  use Reencodarr.DataCase, async: true

  alias Reencodarr.Media

  setup do
    {:ok, video} =
      Fixtures.video_fixture(%{
        path: "/test/choose_best.mkv",
        # 10 GiB → target 95
        size: 10 * 1024 * 1024 * 1024,
        bitrate: 5000,
        state: :crf_searching,
        video_codecs: ["h264"],
        audio_codecs: ["aac"],
        max_audio_channels: 6,
        atmos: false
      })

    %{video: video}
  end

  describe "choose_best_vmaf/1" do
    test "chooses VMAF meeting target with lowest percent", %{video: video} do
      # Two VMAFs that meet target (95): prefer lower percent (smaller file)
      _v1 = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 20.0, score: 96.0, percent: 30})
      _v2 = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 25.0, score: 95.5, percent: 20})

      {:ok, chosen} = Media.choose_best_vmaf(video)
      assert chosen.crf == 25.0
      assert Media.chosen_vmaf_exists?(video)
    end

    test "falls back to highest score when none meet target", %{video: video} do
      # Both below target 95
      _v1 = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 30.0, score: 90.0, percent: 10})
      _v2 = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 28.0, score: 92.0, percent: 15})

      {:ok, chosen} = Media.choose_best_vmaf(video)
      assert chosen.crf == 28.0
      assert chosen.score == 92.0
    end

    test "returns error when no VMAFs exist", %{video: video} do
      assert {:error, :no_vmafs} = Media.choose_best_vmaf(video)
    end

    test "marks the chosen VMAF in the database", %{video: video} do
      _v1 = Fixtures.vmaf_fixture(%{video_id: video.id, crf: 23.0, score: 95.5, percent: 25})

      {:ok, _} = Media.choose_best_vmaf(video)

      # Verify via direct query
      updated_video = Media.get_video(video.id)
      assert updated_video.chosen_vmaf_id != nil
      vmafs = Media.get_vmafs_for_video(video.id)
      chosen = Enum.find(vmafs, &(&1.id == updated_video.chosen_vmaf_id))
      assert chosen != nil
      assert chosen.crf == 23.0
    end
  end
end
