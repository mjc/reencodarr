defmodule Reencodarr.Media.OrphanResetTest do
  @moduledoc """
  Tests for Media.reset_orphaned_crf_searching/0 and Media.reset_orphaned_encoding/0.
  """
  use Reencodarr.DataCase, async: true

  alias Reencodarr.Media

  describe "reset_orphaned_crf_searching/0" do
    test "resets crf_searching videos to analyzed" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/orphan_crf.mkv",
          state: :crf_searching,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      assert :ok = Media.reset_orphaned_crf_searching()

      updated = Media.get_video(video.id)
      assert updated.state == :analyzed
    end

    test "does not affect videos in other states" do
      {:ok, analyzed} =
        Fixtures.video_fixture(%{
          path: "/test/orphan_analyzed.mkv",
          state: :analyzed,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      {:ok, encoded} =
        Fixtures.video_fixture(%{
          path: "/test/orphan_encoded.mkv",
          state: :encoded,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      assert :ok = Media.reset_orphaned_crf_searching()

      assert Media.get_video(analyzed.id).state == :analyzed
      assert Media.get_video(encoded.id).state == :encoded
    end

    test "returns :ok when no orphans exist" do
      assert :ok = Media.reset_orphaned_crf_searching()
    end
  end

  describe "reset_orphaned_encoding/0" do
    test "resets encoding video with chosen VMAF back to crf_searched" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/orphan_enc_vmaf.mkv",
          state: :encoding,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      Fixtures.vmaf_fixture(%{video_id: video.id, chosen: true, crf: 25.0})

      assert :ok = Media.reset_orphaned_encoding()

      assert Media.get_video(video.id).state == :crf_searched
    end

    test "resets encoding video without chosen VMAF back to analyzed" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/orphan_enc_no_vmaf.mkv",
          state: :encoding,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      assert :ok = Media.reset_orphaned_encoding()

      assert Media.get_video(video.id).state == :analyzed
    end

    test "does not affect videos in other states" do
      {:ok, crf_searched} =
        Fixtures.video_fixture(%{
          path: "/test/orphan_crfs.mkv",
          state: :crf_searched,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      assert :ok = Media.reset_orphaned_encoding()

      assert Media.get_video(crf_searched.id).state == :crf_searched
    end

    test "returns :ok when no orphaned encoding videos exist" do
      assert :ok = Media.reset_orphaned_encoding()
    end
  end

  describe "reset_crf_searched_without_vmaf/0" do
    test "resets crf_searched video with no chosen VMAF to analyzed" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/crf_searched_no_vmaf.mkv",
          state: :crf_searched,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      assert :ok = Media.reset_crf_searched_without_vmaf()

      assert Media.get_video(video.id).state == :analyzed
    end

    test "leaves crf_searched video with a chosen VMAF untouched" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/crf_searched_with_vmaf.mkv",
          state: :crf_searched,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      Fixtures.vmaf_fixture(%{video_id: video.id, chosen: true, crf: 25.0})

      assert :ok = Media.reset_crf_searched_without_vmaf()

      assert Media.get_video(video.id).state == :crf_searched
    end

    test "does not affect videos in other states" do
      {:ok, analyzed} =
        Fixtures.video_fixture(%{
          path: "/test/rcsv_analyzed.mkv",
          state: :analyzed,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      assert :ok = Media.reset_crf_searched_without_vmaf()

      assert Media.get_video(analyzed.id).state == :analyzed
    end

    test "returns :ok when no such videos exist" do
      assert :ok = Media.reset_crf_searched_without_vmaf()
    end
  end
end
