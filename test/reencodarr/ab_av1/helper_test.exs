defmodule Reencodarr.AbAv1.HelperTest do
  @moduledoc """
  Tests for Helper module attachment cleaning and utility functions.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  @moduletag capture_log: true

  alias Reencodarr.AbAv1.Helper

  setup do
    # Clean up any existing mocks
    case :meck.unload() do
      :ok -> :ok
      _ -> :ok
    end

    :ok
  end

  describe "clean_attachments/1 - detection" do
    test "returns original path when ffprobe finds no attached pictures" do
      file_path = "/media/clean_movie.mkv"

      ffprobe_response =
        Jason.encode!(%{
          "streams" => [
            %{
              "codec_name" => "hevc",
              "codec_type" => "video",
              "disposition" => %{"attached_pic" => 0}
            },
            %{"codec_name" => "aac", "codec_type" => "audio", "disposition" => %{}}
          ]
        })

      :meck.new(System, [:passthrough])

      :meck.expect(System, :cmd, fn
        "ffprobe", _, _ -> {ffprobe_response, 0}
      end)

      assert {:ok, ^file_path} = Helper.clean_attachments(file_path)

      # Verify ffprobe was called
      assert :meck.called(System, :cmd, ["ffprobe", :_, :_])
      # Verify no cleaning tools were called
      refute :meck.called(System, :cmd, ["mkvpropedit", :_, :_])
      refute :meck.called(System, :cmd, ["MP4Box", :_, :_])
      refute :meck.called(System, :cmd, ["ffmpeg", :_, :_])

      :meck.unload(System)
    end

    test "returns original path when ffprobe fails" do
      file_path = "/media/broken.mkv"

      :meck.new(System, [:passthrough])

      :meck.expect(System, :cmd, fn
        "ffprobe", _, _ -> {"error output", 1}
      end)

      assert {:ok, ^file_path} = Helper.clean_attachments(file_path)

      :meck.unload(System)
    end

    test "detects streams with attached_pic disposition" do
      file_path = "/media/movie_with_cover.mkv"

      ffprobe_with_images =
        Jason.encode!(%{
          "streams" => [
            %{
              "codec_name" => "hevc",
              "codec_type" => "video",
              "disposition" => %{"attached_pic" => 0}
            },
            %{
              "codec_name" => "mjpeg",
              "codec_type" => "video",
              "index" => 1,
              "disposition" => %{"attached_pic" => 1}
            }
          ]
        })

      ffprobe_clean =
        Jason.encode!(%{
          "streams" => [
            %{
              "codec_name" => "hevc",
              "codec_type" => "video",
              "disposition" => %{"attached_pic" => 0}
            }
          ]
        })

      counter = :counters.new(1, [:atomics])
      :meck.new(System, [:passthrough])

      :meck.expect(System, :cmd, fn
        "ffprobe", _, _ ->
          :counters.add(counter, 1, 1)

          if :counters.get(counter, 1) == 1,
            do: {ffprobe_with_images, 0},
            else: {ffprobe_clean, 0}

        "mkvpropedit", _, _ ->
          {"Done.\n", 0}
      end)

      assert {:ok, ^file_path} = Helper.clean_attachments(file_path)

      # Verify mkvpropedit was called
      assert :meck.called(System, :cmd, ["mkvpropedit", :_, :_])

      :meck.unload(System)
    end

    test "detects mjpeg codec streams" do
      file_path = "/media/movie_mjpeg.mkv"

      ffprobe_response =
        Jason.encode!(%{
          "streams" => [
            %{"codec_name" => "hevc", "codec_type" => "video"},
            %{"codec_name" => "mjpeg", "codec_type" => "video", "index" => 1}
          ]
        })

      :meck.new(System, [:passthrough])

      :meck.expect(System, :cmd, fn
        "ffprobe", _, _ -> {ffprobe_response, 0}
        "mkvpropedit", _, _ -> {"Done.\n", 0}
        "ffmpeg", _, _ -> {"ffmpeg output", 0}
      end)

      # Should detect mjpeg and clean
      {:ok, result_path} = Helper.clean_attachments(file_path)

      # Since it's MJPEG video track (not attachment), should fall back to ffmpeg
      assert result_path != file_path
      assert :meck.called(System, :cmd, ["ffmpeg", :_, :_])

      :meck.unload(System)
    end
  end

  describe "clean_attachments/1 - MKV cleaning" do
    test "calls mkvpropedit in-place for MKV with image attachments" do
      file_path = "/media/movie.mkv"

      ffprobe_with_images =
        Jason.encode!(%{
          "streams" => [
            %{
              "codec_name" => "hevc",
              "codec_type" => "video",
              "disposition" => %{"attached_pic" => 0}
            },
            %{
              "codec_name" => "mjpeg",
              "codec_type" => "video",
              "index" => 42,
              "disposition" => %{"attached_pic" => 1}
            }
          ]
        })

      ffprobe_clean =
        Jason.encode!(%{
          "streams" => [
            %{
              "codec_name" => "hevc",
              "codec_type" => "video",
              "disposition" => %{"attached_pic" => 0}
            }
          ]
        })

      counter = :counters.new(1, [:atomics])
      :meck.new(System, [:passthrough])

      :meck.expect(System, :cmd, fn
        "ffprobe", _, _ ->
          :counters.add(counter, 1, 1)

          if :counters.get(counter, 1) == 1,
            do: {ffprobe_with_images, 0},
            else: {ffprobe_clean, 0}

        "mkvpropedit", [^file_path | _], _ ->
          {"Done.\n", 0}
      end)

      assert {:ok, ^file_path} = Helper.clean_attachments(file_path)

      # Verify mkvpropedit was called (not ffmpeg)
      assert :meck.called(System, :cmd, ["mkvpropedit", :_, :_])
      refute :meck.called(System, :cmd, ["ffmpeg", :_, :_])

      :meck.unload(System)
    end

    test "does not create temp files for MKV attachment-only case" do
      file_path = "/media/movie.MKV"

      ffprobe_with_images =
        Jason.encode!(%{
          "streams" => [
            %{"codec_name" => "hevc", "codec_type" => "video"},
            %{
              "codec_name" => "png",
              "codec_type" => "video",
              "index" => 1,
              "disposition" => %{"attached_pic" => 1}
            }
          ]
        })

      ffprobe_clean =
        Jason.encode!(%{
          "streams" => [
            %{
              "codec_name" => "hevc",
              "codec_type" => "video",
              "disposition" => %{"attached_pic" => 0}
            }
          ]
        })

      counter = :counters.new(1, [:atomics])
      :meck.new(System, [:passthrough])

      :meck.expect(System, :cmd, fn
        "ffprobe", _, _ ->
          :counters.add(counter, 1, 1)

          if :counters.get(counter, 1) == 1,
            do: {ffprobe_with_images, 0},
            else: {ffprobe_clean, 0}

        "mkvpropedit", _, _ ->
          {"Done.\n", 0}
      end)

      {:ok, result_path} = Helper.clean_attachments(file_path)

      # Should return original path (in-place edit)
      assert result_path == file_path

      :meck.unload(System)
    end

    test "falls back to ffmpeg remux for MKV with MJPEG video tracks" do
      file_path = "/media/movie_mjpeg_track.mkv"

      ffprobe_response =
        Jason.encode!(%{
          "streams" => [
            %{"codec_name" => "hevc", "codec_type" => "video"},
            %{
              "codec_name" => "mjpeg",
              "codec_type" => "video",
              "index" => 1,
              "disposition" => %{"attached_pic" => 0}
            }
          ]
        })

      :meck.new(System, [:passthrough])

      :meck.expect(System, :cmd, fn
        "ffprobe", _, _ -> {ffprobe_response, 0}
        "mkvpropedit", _, _ -> {"Done.\n", 0}
        "ffmpeg", _, _ -> {"ffmpeg output", 0}
      end)

      {:ok, result_path} = Helper.clean_attachments(file_path)

      # Should use ffmpeg remux (creates temp file)
      assert result_path != file_path
      assert :meck.called(System, :cmd, ["ffmpeg", :_, :_])

      :meck.unload(System)
    end
  end

  describe "clean_attachments/1 - MP4 cleaning" do
    test "calls MP4Box -rem for MP4 with attached pictures" do
      file_path = "/media/movie.mp4"

      ffprobe_with_images =
        Jason.encode!(%{
          "streams" => [
            %{"codec_name" => "hevc", "codec_type" => "video"},
            %{
              "codec_name" => "mjpeg",
              "codec_type" => "video",
              "index" => 1,
              "disposition" => %{"attached_pic" => 1}
            }
          ]
        })

      ffprobe_clean =
        Jason.encode!(%{
          "streams" => [
            %{
              "codec_name" => "hevc",
              "codec_type" => "video",
              "disposition" => %{"attached_pic" => 0}
            }
          ]
        })

      counter = :counters.new(1, [:atomics])
      :meck.new(System, [:passthrough])

      :meck.expect(System, :cmd, fn
        "ffprobe", _, _ ->
          :counters.add(counter, 1, 1)

          if :counters.get(counter, 1) == 1,
            do: {ffprobe_with_images, 0},
            else: {ffprobe_clean, 0}

        "MP4Box", ["-rem", "2", ^file_path], _ ->
          {"Done.\n", 0}
      end)

      assert {:ok, ^file_path} = Helper.clean_attachments(file_path)

      # Verify MP4Box was called with correct track number (index + 1)
      assert :meck.called(System, :cmd, ["MP4Box", ["-rem", "2", file_path], :_])
      refute :meck.called(System, :cmd, ["ffmpeg", :_, :_])
      # Verify ffprobe was called twice (detection + verification)
      assert :counters.get(counter, 1) == 2

      :meck.unload(System)
    end

    test "handles .m4v extension" do
      file_path = "/media/movie.m4v"

      ffprobe_with_images =
        Jason.encode!(%{
          "streams" => [
            %{"codec_name" => "hevc", "codec_type" => "video"},
            %{
              "codec_name" => "png",
              "codec_type" => "video",
              "index" => 2,
              "disposition" => %{"attached_pic" => 1}
            }
          ]
        })

      ffprobe_clean =
        Jason.encode!(%{
          "streams" => [
            %{
              "codec_name" => "hevc",
              "codec_type" => "video",
              "disposition" => %{"attached_pic" => 0}
            }
          ]
        })

      counter = :counters.new(1, [:atomics])
      :meck.new(System, [:passthrough])

      :meck.expect(System, :cmd, fn
        "ffprobe", _, _ ->
          :counters.add(counter, 1, 1)

          if :counters.get(counter, 1) == 1,
            do: {ffprobe_with_images, 0},
            else: {ffprobe_clean, 0}

        "MP4Box", ["-rem", "3", ^file_path], _ ->
          {"Done.\n", 0}
      end)

      assert {:ok, ^file_path} = Helper.clean_attachments(file_path)

      assert :meck.called(System, :cmd, ["MP4Box", ["-rem", "3", file_path], :_])

      :meck.unload(System)
    end

    test "handles multiple attached pictures" do
      file_path = "/media/movie.MP4"

      ffprobe_with_images =
        Jason.encode!(%{
          "streams" => [
            %{"codec_name" => "hevc", "codec_type" => "video"},
            %{
              "codec_name" => "mjpeg",
              "codec_type" => "video",
              "index" => 1,
              "disposition" => %{"attached_pic" => 1}
            },
            %{
              "codec_name" => "png",
              "codec_type" => "video",
              "index" => 2,
              "disposition" => %{"attached_pic" => 1}
            }
          ]
        })

      ffprobe_clean =
        Jason.encode!(%{
          "streams" => [
            %{
              "codec_name" => "hevc",
              "codec_type" => "video",
              "disposition" => %{"attached_pic" => 0}
            }
          ]
        })

      counter = :counters.new(1, [:atomics])
      :meck.new(System, [:passthrough])

      :meck.expect(System, :cmd, fn
        "ffprobe", _, _ ->
          :counters.add(counter, 1, 1)

          if :counters.get(counter, 1) == 1,
            do: {ffprobe_with_images, 0},
            else: {ffprobe_clean, 0}

        "MP4Box", ["-rem", _track_num, ^file_path], _ ->
          {"Done.\n", 0}
      end)

      assert {:ok, ^file_path} = Helper.clean_attachments(file_path)

      # Verify MP4Box was called twice (once per track, descending order)
      assert :meck.called(System, :cmd, ["MP4Box", ["-rem", "3", file_path], :_])
      assert :meck.called(System, :cmd, ["MP4Box", ["-rem", "2", file_path], :_])
      # Verify ffprobe was called twice (detection + verification)
      assert :counters.get(counter, 1) == 2

      :meck.unload(System)
    end

    test "falls back to ffmpeg remux when MP4Box fails" do
      file_path = "/media/movie.mp4"

      ffprobe_response =
        Jason.encode!(%{
          "streams" => [
            %{"codec_name" => "hevc", "codec_type" => "video"},
            %{
              "codec_name" => "mjpeg",
              "codec_type" => "video",
              "index" => 1,
              "disposition" => %{"attached_pic" => 1}
            }
          ]
        })

      :meck.new(System, [:passthrough])

      :meck.expect(System, :cmd, fn
        "ffprobe", _, _ -> {ffprobe_response, 0}
        "MP4Box", _, _ -> {"Error: invalid track\n", 1}
        "ffmpeg", _, _ -> {"ffmpeg output", 0}
      end)

      {:ok, result_path} = Helper.clean_attachments(file_path)

      # Should fall back to ffmpeg
      assert result_path != file_path
      assert :meck.called(System, :cmd, ["MP4Box", :_, :_])
      assert :meck.called(System, :cmd, ["ffmpeg", :_, :_])

      :meck.unload(System)
    end
  end

  describe "clean_attachments/1 - ffmpeg remux fallback" do
    test "remuxes non-MKV/non-MP4 files with -map 0:V" do
      file_path = "/media/movie.avi"

      ffprobe_response =
        Jason.encode!(%{
          "streams" => [
            %{"codec_name" => "hevc", "codec_type" => "video"},
            %{
              "codec_name" => "mjpeg",
              "codec_type" => "video",
              "index" => 1,
              "disposition" => %{"attached_pic" => 1}
            }
          ]
        })

      :meck.new(System, [:passthrough])

      :meck.expect(System, :cmd, fn
        "ffprobe", _, _ -> {ffprobe_response, 0}
        "ffmpeg", _args, _ -> {"ffmpeg output", 0}
      end)

      {:ok, result_path} = Helper.clean_attachments(file_path)

      # Should use ffmpeg remux
      assert result_path != file_path
      assert String.ends_with?(result_path, "_cleaned.avi")
      assert :meck.called(System, :cmd, ["ffmpeg", :_, :_])

      :meck.unload(System)
    end

    test "returns original path when ffmpeg remux fails" do
      file_path = "/media/movie.avi"

      ffprobe_response =
        Jason.encode!(%{
          "streams" => [
            %{"codec_name" => "hevc", "codec_type" => "video"},
            %{"codec_name" => "png", "codec_type" => "video", "index" => 1}
          ]
        })

      :meck.new(System, [:passthrough])

      :meck.expect(System, :cmd, fn
        "ffprobe", _, _ -> {ffprobe_response, 0}
        "ffmpeg", _, _ -> {"Error: could not remux\n", 1}
      end)

      :meck.new(File, [:unstick, :passthrough])
      :meck.expect(File, :rm, fn _ -> :ok end)

      assert {:ok, ^file_path} = Helper.clean_attachments(file_path)

      :meck.unload(File)
      :meck.unload(System)
    end
  end

  describe "attach_params/2" do
    test "attaches video_id to each vmaf map" do
      video = %{id: 123}

      vmafs = [
        %{"crf" => 20, "vmaf" => 95.0},
        %{"crf" => 22, "vmaf" => 93.5}
      ]

      result = Helper.attach_params(vmafs, video)

      assert result == [
               %{"crf" => 20, "vmaf" => 95.0, "video_id" => 123},
               %{"crf" => 22, "vmaf" => 93.5, "video_id" => 123}
             ]
    end

    test "handles empty list" do
      video = %{id: 456}
      vmafs = []

      result = Helper.attach_params(vmafs, video)

      assert result == []
    end
  end

  describe "remove_args/2" do
    test "removes flag and its value" do
      args = ["--input", "file.mkv", "--preset", "6", "--output", "out.mkv"]
      keys = ["--preset"]

      result = Helper.remove_args(args, keys)

      assert result == ["--input", "file.mkv", "--output", "out.mkv"]
    end

    test "removes multiple flags" do
      args = ["--input", "file.mkv", "--preset", "6", "--temp-dir", "/tmp", "--output", "out.mkv"]
      keys = ["--preset", "--temp-dir"]

      result = Helper.remove_args(args, keys)

      assert result == ["--input", "file.mkv", "--output", "out.mkv"]
    end

    test "handles missing flags" do
      args = ["--input", "file.mkv", "--output", "out.mkv"]
      keys = ["--preset"]

      result = Helper.remove_args(args, keys)

      assert result == ["--input", "file.mkv", "--output", "out.mkv"]
    end

    test "handles empty args" do
      args = []
      keys = ["--preset"]

      result = Helper.remove_args(args, keys)

      assert result == []
    end

    test "handles empty keys" do
      args = ["--input", "file.mkv", "--preset", "6"]
      keys = []

      result = Helper.remove_args(args, keys)

      assert result == ["--input", "file.mkv", "--preset", "6"]
    end
  end

  describe "open_port/1" do
    test "returns {:ok, port} when ab-av1 executable exists" do
      # Create a temp file for testing
      test_file = Path.join(System.tmp_dir!(), "test_open_port_#{:rand.uniform(1000)}.mkv")
      File.write!(test_file, "test content")

      # Find a real executable to use as a stand-in for ab-av1
      cat_path = System.find_executable("cat")
      ffprobe_path = System.find_executable("ffprobe")

      # Mock System.find_executable to return a valid executable path (use cat as a stand-in)
      :meck.new(System, [:passthrough])

      :meck.expect(System, :find_executable, fn
        "ab-av1" -> cat_path
        "ffprobe" -> ffprobe_path
      end)

      args = ["crf-search", "--input", test_file]

      result = Helper.open_port(args)

      assert {:ok, port} = result
      assert is_port(port)

      # Clean up the port and temp file
      Port.close(port)
      File.rm(test_file)

      :meck.unload(System)
    end

    test "returns {:error, :not_found} when ab-av1 executable is missing" do
      capture_log(fn ->
        ffprobe_path = System.find_executable("ffprobe")

        # Mock System.find_executable to return nil
        :meck.new(System, [:passthrough])

        :meck.expect(System, :find_executable, fn
          "ab-av1" -> nil
          "ffprobe" -> ffprobe_path
        end)

        args = ["crf-search", "--input", "/tmp/test.mkv"]

        result = Helper.open_port(args)

        assert {:error, :not_found} = result

        :meck.unload(System)
      end)
    end
  end

  describe "build_rules/1" do
    test "returns a list of args" do
      video = %Reencodarr.Media.Video{path: "/test/video.mkv", width: 1920, height: 1080}
      result = Helper.build_rules(video)
      assert is_list(result)
    end

    test "does not include --acodec in crf_search context" do
      video = %Reencodarr.Media.Video{path: "/test/video.mkv", width: 1920, height: 1080}
      result = Helper.build_rules(video)
      refute "--acodec" in result
    end

    test "includes svt av1 encoder args" do
      video = %Reencodarr.Media.Video{path: "/test/video.mkv", width: 1920, height: 1080}
      result = Helper.build_rules(video)
      assert "--encoder" in result
      assert "svt-av1" in result
    end
  end

  describe "temp_dir/0" do
    test "returns a non-empty string path" do
      result = Helper.temp_dir()
      assert is_binary(result)
      assert String.length(result) > 0
    end

    test "returns an existing directory" do
      result = Helper.temp_dir()
      assert File.exists?(result)
      assert File.dir?(result)
    end
  end

  describe "close_port/1" do
    test "returns :ok for :none" do
      assert :ok = Helper.close_port(:none)
    end
  end

  describe "kill_os_process/1" do
    test "returns :ok for nil pid" do
      assert :ok = Helper.kill_os_process(nil)
    end

    test "returns :ok for non-existent pid (graceful failure)" do
      # PID 9_999_999 almost certainly doesn't exist; signal is gracefully rescued
      assert :ok = Helper.kill_os_process(9_999_999)
    end
  end
end
