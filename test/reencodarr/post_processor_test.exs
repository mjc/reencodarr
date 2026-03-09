defmodule Reencodarr.PostProcessorTest do
  use Reencodarr.DataCase, async: false
  import ExUnit.CaptureLog
  require Logger

  alias Reencodarr.{Media, PostProcessor}

  # ---------------------------------------------------------------------------
  # process_encoding_success/2
  # ---------------------------------------------------------------------------

  describe "process_encoding_success/2 happy path" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "pp_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf(tmp) end)
      %{tmp: tmp}
    end

    test "returns {:ok, :success}, marks video :encoded, moves encoded file", %{tmp: tmp} do
      video_path = Path.join(tmp, "video.mkv")
      output_file = Path.join(tmp, "output.mkv")

      File.write!(video_path, "original content (large)")
      File.write!(output_file, "encoded content (smaller)")

      {:ok, video} = Fixtures.video_fixture(%{path: video_path, size: 24})

      capture_log(fn ->
        assert {:ok, :success} = PostProcessor.process_encoding_success(video, output_file)
      end)

      # Encoded output consumed
      refute File.exists?(output_file)
      # Final destination has content
      assert File.exists?(video_path)
      # Video with encoded content
      assert File.read!(video_path) == "encoded content (smaller)"
      # DB: state is :encoded
      updated = Media.get_video!(video.id)
      assert updated.state == :encoded
    end

    test "stores original_size in DB before overwrite", %{tmp: tmp} do
      video_path = Path.join(tmp, "video2.mkv")
      output_file = Path.join(tmp, "output2.mkv")

      File.write!(video_path, String.duplicate("x", 100))
      File.write!(output_file, "smaller")

      {:ok, video} = Fixtures.video_fixture(%{path: video_path, size: 100})
      assert is_nil(video.original_size)

      capture_log(fn ->
        PostProcessor.process_encoding_success(video, output_file)
      end)

      updated = Media.get_video!(video.id)
      assert updated.original_size == 100
    end

    test "does not overwrite original_size when already set", %{tmp: tmp} do
      video_path = Path.join(tmp, "video3.mkv")
      output_file = Path.join(tmp, "output3.mkv")

      File.write!(video_path, "original")
      File.write!(output_file, "smaller")

      {:ok, video} = Fixtures.video_fixture(%{path: video_path, size: 8})
      {:ok, video} = Media.update_video(video, %{original_size: 9999})

      capture_log(fn ->
        PostProcessor.process_encoding_success(video, output_file)
      end)

      updated = Media.get_video!(video.id)
      assert updated.original_size == 9999
    end

    test "intermediate file is cleaned up (not left on disk)", %{tmp: tmp} do
      video_path = Path.join(tmp, "video4.mkv")
      output_file = Path.join(tmp, "output4.mkv")

      File.write!(video_path, "original")
      File.write!(output_file, "encoded")

      {:ok, video} = Fixtures.video_fixture(%{path: video_path, size: 8})

      capture_log(fn ->
        PostProcessor.process_encoding_success(video, output_file)
      end)

      int_path = Reencodarr.FileOperations.calculate_intermediate_path(video)
      refute File.exists?(int_path)
    end

    test "larger encoded file is accepted with a warning (no size gate)", %{tmp: tmp} do
      video_path = Path.join(tmp, "video5.mkv")
      output_file = Path.join(tmp, "output5.mkv")

      File.write!(video_path, "sm")
      # Encoded file larger than original
      File.write!(output_file, "much larger encoded output here!")

      {:ok, video} = Fixtures.video_fixture(%{path: video_path, size: 2})

      capture_log(fn ->
        assert {:ok, :success} = PostProcessor.process_encoding_success(video, output_file)
      end)

      updated = Media.get_video!(video.id)
      assert updated.state == :encoded
    end
  end

  describe "process_encoding_success/2 failure paths" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "pp_fail_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf(tmp) end)
      %{tmp: tmp}
    end

    test "returns {:error, :verification_failed} when output file does not exist", %{tmp: tmp} do
      video_path = Path.join(tmp, "video.mkv")
      File.write!(video_path, "original")
      {:ok, video} = Fixtures.video_fixture(%{path: video_path, size: 8})

      log =
        capture_log(fn ->
          assert {:error, :verification_failed} =
                   PostProcessor.process_encoding_success(
                     video,
                     "/nonexistent/path/output.mkv"
                   )
        end)

      assert log =~ "verification failed" or log =~ "not found" or
               log =~ "Post-encode"
    end

    test "returns {:error, :verification_failed} for 0-byte output file", %{tmp: tmp} do
      video_path = Path.join(tmp, "video.mkv")
      output_file = Path.join(tmp, "output_empty.mkv")

      File.write!(video_path, "original")
      File.write!(output_file, "")

      {:ok, video} = Fixtures.video_fixture(%{path: video_path, size: 8})

      capture_log(fn ->
        assert {:error, :verification_failed} =
                 PostProcessor.process_encoding_success(video, output_file)
      end)

      # Empty file should be cleaned up
      refute File.exists?(output_file)
    end

    test "records a failure entry in video_failures on verification failure", %{tmp: tmp} do
      video_path = Path.join(tmp, "video.mkv")
      File.write!(video_path, "original")
      {:ok, video} = Fixtures.video_fixture(%{path: video_path, size: 8})

      capture_log(fn ->
        PostProcessor.process_encoding_success(video, "/nonexistent/output.mkv")
      end)

      failures = Media.get_video_failures(video.id)
      assert failures != []
    end
  end

  # ---------------------------------------------------------------------------
  # process_encoding_failure/3
  # ---------------------------------------------------------------------------

  describe "process_encoding_failure/3" do
    test "returns :ok" do
      {:ok, video} = Fixtures.video_fixture()

      capture_log(fn ->
        assert :ok =
                 PostProcessor.process_encoding_failure(video, 1, %{
                   command: "ab-av1 encode ...",
                   full_output: "some error output"
                 })
      end)
    end

    test "records an encode failure entry in the DB" do
      {:ok, video} = Fixtures.video_fixture()

      capture_log(fn ->
        PostProcessor.process_encoding_failure(video, 255, %{
          command: "ab-av1 encode",
          full_output: "fatal error"
        })
      end)

      failures = Media.get_video_failures(video.id)
      assert failures != []
      failure = hd(failures)
      assert failure.failure_stage == :encoding
      assert failure.resolved == false
    end

    test "returns :ok with empty context map" do
      {:ok, video} = Fixtures.video_fixture()

      capture_log(fn ->
        assert :ok = PostProcessor.process_encoding_failure(video, -1, %{})
      end)
    end

    test "transitions video state to :failed" do
      {:ok, video} = Fixtures.video_fixture(%{state: :needs_analysis})

      capture_log(fn ->
        PostProcessor.process_encoding_failure(video, 1, %{})
      end)

      updated = Media.get_video!(video.id)
      assert updated.state == :failed
    end

    test "handles signal kill exit code (137)" do
      {:ok, video} = Fixtures.video_fixture()

      capture_log(fn ->
        assert :ok =
                 PostProcessor.process_encoding_failure(video, 137, %{
                   command: "ab-av1 encode --crf 28",
                   full_output: "Killed"
                 })
      end)

      failures = Media.get_video_failures(video.id)
      assert failures != []
    end

    test "handles exit code 255" do
      {:ok, video} = Fixtures.video_fixture()

      capture_log(fn ->
        assert :ok =
                 PostProcessor.process_encoding_failure(video, 255, %{
                   command: "ab-av1 encode",
                   full_output: "Unknown error"
                 })
      end)

      failures = Media.get_video_failures(video.id)
      assert failures != []
    end

    test "logs the exit code and video path" do
      {:ok, video} = Fixtures.video_fixture(%{path: "/test/videos/logged_video.mkv"})

      log =
        capture_log(fn ->
          PostProcessor.process_encoding_failure(video, 42, %{})
        end)

      assert log =~ "exit code 42"
      assert log =~ "#{video.id}"
    end

    test "uses default empty context when not provided" do
      {:ok, video} = Fixtures.video_fixture()

      capture_log(fn ->
        assert :ok = PostProcessor.process_encoding_failure(video, 1)
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # verify_encoded_output edge cases (tested via process_encoding_success)
  # ---------------------------------------------------------------------------

  describe "verify_encoded_output edge cases via process_encoding_success/2" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "pp_verify_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf(tmp) end)
      %{tmp: tmp}
    end

    test "succeeds when original size is very small", %{tmp: tmp} do
      video_path = Path.join(tmp, "small_orig.mkv")
      output_file = Path.join(tmp, "small_output.mkv")

      File.write!(video_path, "x")
      File.write!(output_file, "y")

      {:ok, video} = Fixtures.video_fixture(%{path: video_path, size: 1})

      capture_log(fn ->
        assert {:ok, :success} = PostProcessor.process_encoding_success(video, output_file)
      end)
    end

    test "logs encoded video size information", %{tmp: tmp} do
      video_path = Path.join(tmp, "savings.mkv")
      output_file = Path.join(tmp, "savings_output.mkv")

      File.write!(video_path, String.duplicate("x", 100))
      File.write!(output_file, String.duplicate("y", 50))

      {:ok, video} = Fixtures.video_fixture(%{path: video_path, size: 100})

      prev_level = Logger.level()
      Logger.configure(level: :info)

      log =
        capture_log(fn ->
          PostProcessor.process_encoding_success(video, output_file)
        end)

      Logger.configure(level: prev_level)

      assert log =~ "Encoded video"
      assert log =~ "savings:"
    end

    test "warns when encoded file is larger but still succeeds", %{tmp: tmp} do
      video_path = Path.join(tmp, "larger.mkv")
      output_file = Path.join(tmp, "larger_output.mkv")

      File.write!(video_path, "sm")
      File.write!(output_file, String.duplicate("x", 200))

      {:ok, video} = Fixtures.video_fixture(%{path: video_path, size: 2})

      log =
        capture_log(fn ->
          assert {:ok, :success} = PostProcessor.process_encoding_success(video, output_file)
        end)

      assert log =~ "larger than original"
    end
  end
end
