defmodule Reencodarr.AbAv1.HelperIntegrationTest do
  @moduledoc """
  Integration tests for Helper.clean_attachments/1 using real fixture files.

  These tests exercise the actual ffprobe/MP4Box/mkvpropedit/ffmpeg commands
  against tiny fixture MP4/MKV files, verifying end-to-end cleaning behavior
  for all known image attachment methods.

  Fixture files in test/support/fixtures/mp4_samples/:

  MP4 — covr metadata (iTunes-style, NOT real tracks):
    covr_poster.mp4       — 1 MJPEG in covr atom (attached_pic=1)
    covr_two_posters.mp4  — 2 MJPEGs in covr atom

  MP4 — real video tracks (trak box):
    real_track_poster.mp4 — 1 MJPEG as real track
    two_real_tracks.mp4   — 2 MJPEGs as real tracks
    png_track.mp4         — 1 PNG as real track
    mixed_mjpeg_png.mp4   — MJPEG + PNG as real tracks
    poster.m4v            — M4V extension with real MJPEG track

  Clean baselines:
    clean.mp4             — No attachments
    clean.mkv             — No attachments

  MKV — mkvmerge attachments:
    one_poster.mkv        — 1 JPEG attachment
    two_posters.mkv       — JPEG + PNG attachments
  """
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  alias Reencodarr.AbAv1.Helper

  @fixtures_dir Path.join([File.cwd!(), "test", "support", "fixtures", "mp4_samples"])

  setup do
    # Create a temp dir for test copies (so we don't modify fixtures)
    tmp_dir = Path.join(System.tmp_dir!(), "helper_integration_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  defp copy_fixture(fixture_name, tmp_dir) do
    src = Path.join(@fixtures_dir, fixture_name)
    dest = Path.join(tmp_dir, fixture_name)
    File.cp!(src, dest)
    dest
  end

  defp stream_codecs(file_path) do
    with {output, 0} <-
           System.cmd(
             "ffprobe",
             ["-v", "quiet", "-print_format", "json", "-show_streams", file_path],
             stderr_to_stdout: true
           ),
         {:ok, %{"streams" => streams}} <- Jason.decode(output) do
      Enum.map(streams, fn s ->
        %{
          codec: s["codec_name"],
          attached_pic: get_in(s, ["disposition", "attached_pic"])
        }
      end)
    else
      _ -> []
    end
  end

  defp has_image_stream?(file_path) do
    stream_codecs(file_path)
    |> Enum.any?(fn %{codec: codec, attached_pic: ap} ->
      ap == 1 or codec in ["mjpeg", "png"]
    end)
  end

  # ── Clean files (no attachments) ──────────────────────────────

  describe "clean files — no attachments" do
    test "clean.mp4 returns original path unchanged", %{tmp_dir: tmp_dir} do
      path = copy_fixture("clean.mp4", tmp_dir)
      assert {:ok, ^path} = Helper.clean_attachments(path)
      refute has_image_stream?(path)
    end

    test "clean.mkv returns original path unchanged", %{tmp_dir: tmp_dir} do
      path = copy_fixture("clean.mkv", tmp_dir)
      assert {:ok, ^path} = Helper.clean_attachments(path)
      refute has_image_stream?(path)
    end
  end

  # ── MP4 covr metadata (iTunes-style) ─────────────────────────

  describe "MP4 covr metadata posters" do
    test "covr_poster.mp4 — single covr MJPEG is cleaned via fallback", %{tmp_dir: tmp_dir} do
      path = copy_fixture("covr_poster.mp4", tmp_dir)

      # Verify fixture has the image stream
      assert has_image_stream?(path)

      {:ok, result_path} = Helper.clean_attachments(path)

      # covr metadata causes MP4Box to fail → falls back to ffmpeg remux
      # Result should be a cleaned file without image streams
      refute has_image_stream?(result_path)

      # Should have at least H.264 video stream
      codecs = stream_codecs(result_path)
      assert Enum.any?(codecs, &(&1.codec == "h264"))
    end

    test "covr_two_posters.mp4 — two covr MJPEGs are cleaned", %{tmp_dir: tmp_dir} do
      path = copy_fixture("covr_two_posters.mp4", tmp_dir)

      # Verify fixture has 2 image streams
      image_count =
        stream_codecs(path)
        |> Enum.count(fn %{codec: c, attached_pic: ap} -> ap == 1 or c in ["mjpeg", "png"] end)

      assert image_count == 2

      {:ok, result_path} = Helper.clean_attachments(path)

      refute has_image_stream?(result_path)
      codecs = stream_codecs(result_path)
      assert Enum.any?(codecs, &(&1.codec == "h264"))
    end
  end

  # ── MP4 real video tracks (trak box) ─────────────────────────

  describe "MP4 real MJPEG tracks" do
    test "real_track_poster.mp4 — single real MJPEG track is removed", %{tmp_dir: tmp_dir} do
      path = copy_fixture("real_track_poster.mp4", tmp_dir)

      assert has_image_stream?(path)

      {:ok, result_path} = Helper.clean_attachments(path)

      refute has_image_stream?(result_path)
      codecs = stream_codecs(result_path)
      assert Enum.any?(codecs, &(&1.codec == "h264"))
    end

    test "two_real_tracks.mp4 — both MJPEG tracks are removed", %{tmp_dir: tmp_dir} do
      path = copy_fixture("two_real_tracks.mp4", tmp_dir)

      # Verify fixture has 2 MJPEG streams
      image_count =
        stream_codecs(path)
        |> Enum.count(&(&1.codec == "mjpeg"))

      assert image_count == 2

      {:ok, result_path} = Helper.clean_attachments(path)

      refute has_image_stream?(result_path)
      codecs = stream_codecs(result_path)
      assert Enum.any?(codecs, &(&1.codec == "h264"))
      assert length(codecs) == 1
    end

    test "two_real_tracks.mp4 — both tracks removed regardless of order", %{tmp_dir: tmp_dir} do
      path = copy_fixture("two_real_tracks.mp4", tmp_dir)

      # The key assertion: after cleaning, no MJPEG streams remain
      # This implicitly validates descending removal works (ascending could
      # leave one behind due to track ID shifting on some containers)
      {:ok, result_path} = Helper.clean_attachments(path)

      result_codecs = stream_codecs(result_path)
      refute Enum.any?(result_codecs, &(&1.codec == "mjpeg"))
      assert Enum.any?(result_codecs, &(&1.codec == "h264"))
    end
  end

  # ── PNG tracks ───────────────────────────────────────────────

  describe "PNG image tracks" do
    test "png_track.mp4 — PNG track detected via codec_name and removed", %{tmp_dir: tmp_dir} do
      path = copy_fixture("png_track.mp4", tmp_dir)

      # Verify PNG stream exists (attached_pic=0, detected by codec_name)
      codecs = stream_codecs(path)
      assert Enum.any?(codecs, &(&1.codec == "png"))
      png_stream = Enum.find(codecs, &(&1.codec == "png"))
      assert png_stream.attached_pic == 0

      {:ok, result_path} = Helper.clean_attachments(path)

      refute has_image_stream?(result_path)
      result_codecs = stream_codecs(result_path)
      assert Enum.any?(result_codecs, &(&1.codec == "h264"))
      refute Enum.any?(result_codecs, &(&1.codec == "png"))
    end
  end

  # ── Mixed MJPEG + PNG ───────────────────────────────────────

  describe "mixed image codec tracks" do
    test "mixed_mjpeg_png.mp4 — both MJPEG and PNG tracks removed", %{tmp_dir: tmp_dir} do
      path = copy_fixture("mixed_mjpeg_png.mp4", tmp_dir)

      codecs = stream_codecs(path)
      assert Enum.any?(codecs, &(&1.codec == "mjpeg"))
      assert Enum.any?(codecs, &(&1.codec == "png"))

      {:ok, result_path} = Helper.clean_attachments(path)

      refute has_image_stream?(result_path)
      result_codecs = stream_codecs(result_path)
      assert Enum.any?(result_codecs, &(&1.codec == "h264"))
      assert length(result_codecs) == 1
    end
  end

  # ── M4V extension ───────────────────────────────────────────

  describe "M4V extension handling" do
    test "poster.m4v — dispatched to MP4 cleaning path", %{tmp_dir: tmp_dir} do
      path = copy_fixture("poster.m4v", tmp_dir)

      assert has_image_stream?(path)

      {:ok, result_path} = Helper.clean_attachments(path)

      refute has_image_stream?(result_path)
      codecs = stream_codecs(result_path)
      assert Enum.any?(codecs, &(&1.codec == "h264"))
    end
  end

  # ── MKV attachments ─────────────────────────────────────────

  describe "MKV attachment cleaning" do
    test "one_poster.mkv — JPEG attachment removed via mkvpropedit", %{tmp_dir: tmp_dir} do
      path = copy_fixture("one_poster.mkv", tmp_dir)

      assert has_image_stream?(path)

      {:ok, result_path} = Helper.clean_attachments(path)

      # mkvpropedit works in-place, so same path returned
      assert result_path == path
      refute has_image_stream?(result_path)
    end

    test "two_posters.mkv — both JPEG and PNG attachments removed", %{tmp_dir: tmp_dir} do
      path = copy_fixture("two_posters.mkv", tmp_dir)

      image_count =
        stream_codecs(path)
        |> Enum.count(fn %{attached_pic: ap} -> ap == 1 end)

      assert image_count == 2

      {:ok, result_path} = Helper.clean_attachments(path)

      assert result_path == path
      refute has_image_stream?(result_path)
    end

    test "one_poster.mkv — mkvpropedit cleans in-place and returns same path", %{tmp_dir: tmp_dir} do
      path = copy_fixture("one_poster.mkv", tmp_dir)

      {:ok, result_path} = Helper.clean_attachments(path)

      # mkvpropedit edits in-place — same file, not a temp remux
      assert result_path == path

      # File should be modified (attachments removed) even though path is same
      refute has_image_stream?(result_path)
    end
  end

  # ── Verification behavior ───────────────────────────────────

  describe "post-cleaning verification" do
    test "covr poster falls back to ffmpeg after MP4Box fails", %{tmp_dir: tmp_dir} do
      path = copy_fixture("covr_poster.mp4", tmp_dir)

      {:ok, result_path} = Helper.clean_attachments(path)

      # covr metadata: MP4Box fails → ffmpeg remux fallback
      # Result should be clean (no image streams)
      refute has_image_stream?(result_path)
    end

    test "real track removal succeeds in-place via MP4Box", %{tmp_dir: tmp_dir} do
      path = copy_fixture("real_track_poster.mp4", tmp_dir)

      {:ok, result_path} = Helper.clean_attachments(path)

      # Real track should be removed in-place by MP4Box
      assert result_path == path
      refute has_image_stream?(result_path)
    end
  end
end
