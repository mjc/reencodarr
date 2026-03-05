defmodule Reencodarr.Analyzer.Processing.PipelineTest do
  use ExUnit.Case, async: false

  alias Reencodarr.Analyzer.{Core.FileOperations, MediaInfo.CommandExecutor, Processing.Pipeline}
  alias Reencodarr.Media.MediaInfoExtractor

  setup do
    :meck.unload()
    :ok
  end

  describe "process_single_video/1" do
    test "returns merged params on success" do
      video_info = %{id: 1, path: "/tmp/video1.mkv", service_id: "123", service_type: :sonarr}

      :meck.new(FileOperations, [:passthrough])
      :meck.expect(FileOperations, :validate_file_for_processing, fn _path -> {:ok, %{}} end)

      :meck.new(CommandExecutor, [:passthrough])

      :meck.expect(CommandExecutor, :execute_single_mediainfo, fn _path ->
        {:ok, %{"track" => [%{"@type" => "General"}]}}
      end)

      :meck.new(MediaInfoExtractor, [:passthrough])

      :meck.expect(MediaInfoExtractor, :extract_video_params, fn _mediainfo, _path ->
        %{"width" => 1920, "height" => 1080}
      end)

      assert {:ok, {^video_info, params}} = Pipeline.process_single_video(video_info)
      assert params["width"] == 1920
      assert params["height"] == 1080
      assert params["path"] == video_info.path
      assert params["service_id"] == "123"
      assert params["service_type"] == "sonarr"
    end

    test "returns tagged error when command execution fails" do
      video_info = %{id: 2, path: "/tmp/video2.mkv", service_id: "456", service_type: :radarr}

      :meck.new(FileOperations, [:passthrough])
      :meck.expect(FileOperations, :validate_file_for_processing, fn _path -> {:ok, %{}} end)

      :meck.new(CommandExecutor, [:passthrough])
      :meck.expect(CommandExecutor, :execute_single_mediainfo, fn _path -> {:error, "boom"} end)

      assert {:error, {"/tmp/video2.mkv", "boom"}} = Pipeline.process_single_video(video_info)
    end
  end

  describe "process_video_batch/2" do
    test "returns processed valid videos and marks invalid ones as errors" do
      valid = %{id: 10, path: "/tmp/valid.mkv", service_id: "1", service_type: :sonarr}
      invalid = %{id: 11, path: "/tmp/invalid.mkv", service_id: "2", service_type: :radarr}

      :meck.new(FileOperations, [:passthrough])

      :meck.expect(FileOperations, :validate_files_for_processing, fn _paths ->
        %{
          "/tmp/valid.mkv" => {:ok, %{}},
          "/tmp/invalid.mkv" => {:error, "permission denied"}
        }
      end)

      :meck.new(CommandExecutor, [:passthrough])

      :meck.expect(CommandExecutor, :execute_batch_mediainfo, fn ["/tmp/valid.mkv"] ->
        {:ok, %{"/tmp/valid.mkv" => %{"media" => %{"track" => [%{"@type" => "General"}]}}}}
      end)

      :meck.new(MediaInfoExtractor, [:passthrough])

      :meck.expect(MediaInfoExtractor, :extract_video_params, fn _mediainfo, _path ->
        %{"fps" => 23.976}
      end)

      assert {:ok, results} = Pipeline.process_video_batch([valid, invalid], %{})
      assert {:error, {"/tmp/invalid.mkv", "permission denied"}} in results

      assert Enum.any?(results, fn
               {video, params} when video.path == "/tmp/valid.mkv" ->
                 params["fps"] == 23.976 and params["service_type"] == "sonarr"

               _ ->
                 false
             end)
    end
  end
end
