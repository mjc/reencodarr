defmodule Reencodarr.AbAv1.CrfSearch.GenServerTest do
  @moduledoc """
  Tests for CRF search GenServer behavior and lifecycle.
  """
  use Reencodarr.DataCase, async: false

  alias Reencodarr.AbAv1.CrfSearch
  alias Reencodarr.Media

  import Reencodarr.MediaFixtures
  import ExUnit.CaptureLog

  describe "GenServer lifecycle" do
    setup do
      video = video_fixture(%{path: "/test/genserver_video.mkv", size: 2_000_000_000})
      %{video: video}
    end

    test "starts with no active task" do
      assert CrfSearch.running?() == false
    end

    test "skips CRF search for already reencoded videos", %{video: video} do
      # Mark video as reencoded
      {:ok, reencoded_video} = Media.update_video(video, %{state: :encoded})

      log =
        capture_log(fn ->
          CrfSearch.crf_search(reencoded_video, 95)
        end)

      assert log =~ "Skipping crf search for video"
      assert log =~ "already encoded"
    end

    test "skips CRF search when chosen VMAF already exists", %{video: video} do
      # Create a chosen VMAF record
      {:ok, _vmaf} =
        Media.create_vmaf(%{
          video_id: video.id,
          crf: 28.0,
          score: 95.5,
          params: ["--preset", "medium"],
          chosen: true
        })

      log =
        capture_log(fn ->
          CrfSearch.crf_search(video, 95)
        end)

      assert log =~ "Skipping crf search for video"
      assert log =~ "chosen VMAF already exists"
    end

    test "initiates CRF search for valid video", %{video: video} do
      log =
        capture_log(fn ->
          CrfSearch.crf_search(video, 95)
          # Give it time to process the cast
          Process.sleep(50)
        end)

      assert log =~ "Initiating crf search for video"
      assert log =~ "target VMAF: 95"
    end
  end

  describe "GenServer cast handling" do
    setup do
      video = video_fixture(%{path: "/test/cast_video.mkv", size: 2_000_000_000})
      %{video: video}
    end

    test "handles crf_search cast when not running", %{video: video} do
      log =
        capture_log(fn ->
          GenServer.cast(CrfSearch, {:crf_search, video, 95})
          Process.sleep(50)
        end)

      # Should start the CRF search process
      refute log =~ "already in progress"
    end

    test "rejects crf_search cast when already running", %{video: video} do
      # Start a CRF search first
      GenServer.cast(CrfSearch, {:crf_search, video, 95})
      Process.sleep(50)

      # Try to start another one
      log =
        capture_log(fn ->
          GenServer.cast(CrfSearch, {:crf_search, video, 95})
          Process.sleep(50)
        end)

      assert log =~ "CRF search already in progress"
    end

    test "handles crf_search_with_preset_6 cast", %{video: video} do
      log =
        capture_log(fn ->
          GenServer.cast(CrfSearch, {:crf_search_with_preset_6, video, 95})
          Process.sleep(50)
        end)

      assert log =~ "Starting retry with --preset 6"
    end
  end
end
