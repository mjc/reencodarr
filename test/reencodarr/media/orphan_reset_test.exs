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
    test "resets encoding videos to crf_searched" do
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/orphan_enc.mkv",
          state: :encoding,
          video_codecs: ["h264"],
          audio_codecs: ["aac"]
        })

      assert :ok = Media.reset_orphaned_encoding()

      updated = Media.get_video(video.id)
      assert updated.state == :crf_searched
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
end
