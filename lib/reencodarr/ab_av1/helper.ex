defmodule Reencodarr.AbAv1.Helper do
  @moduledoc """
  Helper functions for ab-av1 operations.

  This module provides utility functions for working with ab-av1 parameters,
  VMAF data processing, and command-line argument manipulation.
  """

  require Logger

  alias Reencodarr.{Media, Rules}

  @spec attach_params(list(map()), Media.Video.t()) :: list(map())
  def attach_params(vmafs, video) do
    Enum.map(vmafs, &Map.put(&1, "video_id", video.id))
  end

  @spec remove_args(list(String.t()), list(String.t())) :: list(String.t())
  def remove_args(args, keys) do
    Enum.reduce(args, {[], false}, fn
      _arg, {acc, true} -> {acc, false}
      arg, {acc, false} -> if Enum.member?(keys, arg), do: {acc, true}, else: {[arg | acc], false}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @spec build_rules(Media.Video.t()) :: list()
  def build_rules(video) do
    Rules.build_args(video, :crf_search)
    |> Enum.reject(&(&1 == "--acodec"))
    |> remove_acodec_values()
  end

  # Remove acodec values that follow --acodec flags
  defp remove_acodec_values(args) do
    args
    |> Enum.with_index()
    |> Enum.reject(fn {arg, idx} ->
      # Remove --acodec flag and its following value
      arg == "--acodec" or
        (idx > 0 and Enum.at(args, idx - 1) == "--acodec")
    end)
    |> Enum.map(&elem(&1, 0))
  end

  @spec temp_dir() :: String.t()
  def temp_dir do
    temp_dir = Application.get_env(:reencodarr, :temp_dir)

    if File.exists?(temp_dir) do
      temp_dir
    else
      case File.mkdir_p(temp_dir) do
        :ok ->
          temp_dir

        {:error, reason} ->
          Logger.error("Failed to create temp directory #{temp_dir}: #{inspect(reason)}")
          # Fallback to system temp directory
          System.tmp_dir!()
      end
    end
  end

  @doc """
  Remove image attachments from video files to prevent FFmpeg encoding failures.

  Some video files contain attached JPEG/PNG images which cause FFmpeg to fail.
  This function uses ffprobe for universal detection and handles cleaning differently
  based on container format:
  - MKV: in-place removal with mkvpropedit (no copy for large files)
  - MP4/other: ffmpeg remux to temp file

  Always returns the path to use - either cleaned temp file or original if cleaning not needed/failed.
  """
  @spec clean_attachments(String.t()) :: {:ok, String.t()}
  def clean_attachments(file_path) do
    case detect_attached_pictures(file_path) do
      {:ok, []} ->
        Logger.debug("No attached pictures found in #{file_path}")
        {:ok, file_path}

      {:ok, attached_pics} ->
        Logger.info(
          "Found #{length(attached_pics)} attached picture(s) in #{file_path}, cleaning..."
        )

        cond do
          mkv?(file_path) -> clean_mkv_in_place(file_path, attached_pics)
          mp4?(file_path) -> clean_mp4_in_place(file_path, attached_pics)
          true -> clean_via_ffmpeg_remux(file_path)
        end

      {:error, reason} ->
        Logger.warning("Failed to detect attachments for #{file_path}: #{inspect(reason)}")
        # If we can't check, assume no attachments and use original file
        {:ok, file_path}
    end
  end

  @spec detect_attached_pictures(String.t()) :: {:ok, list(map())} | {:error, term()}
  defp detect_attached_pictures(file_path) do
    case System.cmd(
           "ffprobe",
           ["-v", "quiet", "-print_format", "json", "-show_streams", file_path],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        parse_attached_pictures(output)

      {_output, _exit_code} ->
        {:error, :ffprobe_failed}
    end
  end

  @spec parse_attached_pictures(String.t()) :: {:ok, list(map())}
  defp parse_attached_pictures(output) do
    case Jason.decode(output) do
      {:ok, %{"streams" => streams}} ->
        pics = Enum.filter(streams, &attached_picture?/1)
        {:ok, pics}

      _ ->
        {:ok, []}
    end
  end

  @spec attached_picture?(map()) :: boolean()
  defp attached_picture?(stream) do
    get_in(stream, ["disposition", "attached_pic"]) == 1 or
      stream["codec_name"] in ["mjpeg", "png"]
  end

  @spec mkv?(String.t()) :: boolean()
  defp mkv?(file_path) do
    String.ends_with?(file_path, [".mkv", ".MKV"])
  end

  @spec mp4?(String.t()) :: boolean()
  defp mp4?(file_path) do
    String.ends_with?(file_path, [".mp4", ".MP4", ".m4v", ".M4V"])
  end

  @spec clean_mkv_in_place(String.t(), list(map())) :: {:ok, String.t()}
  defp clean_mkv_in_place(file_path, attached_pics) do
    # Step 1: Delete image attachments via mkvpropedit (in-place, fast)
    delete_image_attachments(file_path)

    # Step 2: Check if any are actual MJPEG video tracks (not just attachments)
    has_mjpeg_tracks =
      Enum.any?(attached_pics, fn s ->
        s["codec_type"] == "video" and s["codec_name"] == "mjpeg" and
          get_in(s, ["disposition", "attached_pic"]) != 1
      end)

    if has_mjpeg_tracks do
      # mkvpropedit can't delete tracks — fall back to ffmpeg remux
      Logger.info("Found MJPEG video tracks in #{file_path}, using ffmpeg remux")
      clean_via_ffmpeg_remux(file_path)
    else
      Logger.info("Successfully cleaned image attachments from #{file_path} (in-place)")
      {:ok, file_path}
    end
  end

  @spec clean_mp4_in_place(String.t(), list(map())) :: {:ok, String.t()}
  defp clean_mp4_in_place(file_path, attached_pics) do
    # Get track IDs from ffprobe (1-indexed "index" field)
    # MP4Box uses 1-based track numbering that matches ffprobe index + 1
    track_ids = Enum.map(attached_pics, & &1["index"])

    Logger.info("Removing #{length(track_ids)} track(s) from #{file_path} using MP4Box")

    results =
      Enum.map(track_ids, fn idx ->
        # MP4Box track numbering is 1-based, ffprobe index is 0-based
        track_num = idx + 1

        Logger.debug("Removing track #{track_num} from #{file_path}")

        System.cmd("MP4Box", ["-rem", to_string(track_num), file_path], stderr_to_stdout: true)
      end)

    if Enum.all?(results, fn {_, code} -> code == 0 end) do
      Logger.info("Successfully cleaned tracks from #{file_path} (in-place)")
      {:ok, file_path}
    else
      Logger.warning("MP4Box failed, falling back to ffmpeg remux for #{file_path}")
      # Fall back to ffmpeg remux
      clean_via_ffmpeg_remux(file_path)
    end
  end

  @spec clean_via_ffmpeg_remux(String.t()) :: {:ok, String.t()}
  defp clean_via_ffmpeg_remux(file_path) do
    ext = Path.extname(file_path)
    name_without_ext = Path.basename(file_path, ext)
    cleaned = Path.join(temp_dir(), "#{name_without_ext}_cleaned#{ext}")

    Logger.info("Remuxing #{file_path} to remove attached pictures via ffmpeg")

    case System.cmd(
           "ffmpeg",
           [
             "-i",
             file_path,
             "-map",
             "0:V",
             "-map",
             "0:a",
             "-map",
             "0:s?",
             "-c",
             "copy",
             "-y",
             cleaned
           ],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        Logger.info("Successfully remuxed #{file_path} to #{cleaned}")
        {:ok, cleaned}

      {output, code} ->
        Logger.warning(
          "ffmpeg remux failed (#{code}) for #{file_path}: #{String.slice(output, -500..-1//1)}"
        )

        File.rm(cleaned)
        {:ok, file_path}
    end
  end

  defp delete_image_attachments(cleaned_path) do
    attachment_types = ["image/jpg", "image/jpeg", "image/png"]

    Logger.info("Attempting to delete image attachments from #{cleaned_path}")

    result =
      Enum.reduce_while(attachment_types, :ok, fn mime_type, _acc ->
        Logger.debug("Deleting attachments with mime-type: #{mime_type}")

        result =
          System.cmd(
            "mkvpropedit",
            [cleaned_path, "--delete-attachment", "mime-type:#{mime_type}"],
            stderr_to_stdout: true
          )

        handle_mkvpropedit_result(result, mime_type)
      end)

    result
  end

  defp handle_mkvpropedit_result({output, 0}, mime_type) do
    Logger.info("Successfully deleted #{mime_type} attachments: #{output}")
    {:cont, :ok}
  end

  # Exit code 1 or 2 with "No attachment matched" is normal - no attachments of this type
  defp handle_mkvpropedit_result({output, exit_code}, mime_type)
       when exit_code in [1, 2] do
    if String.contains?(output, "No attachment matched") or
         String.contains?(output, "No changes were made") do
      Logger.debug("No #{mime_type} attachments found")
    else
      Logger.warning("mkvpropedit warning for #{mime_type}: exit #{exit_code}, output: #{output}")
    end

    {:cont, :ok}
  end

  defp handle_mkvpropedit_result({output, exit_code}, mime_type) do
    Logger.warning("mkvpropedit failed for #{mime_type}: exit #{exit_code}, output: #{output}")

    {:cont, :ok}
  end

  @spec open_port([binary()]) :: {:ok, port()} | {:error, :not_found}
  def open_port(args) do
    # Preprocess input file to remove image streams/attachments
    {:ok, cleaned_args} = preprocess_input_file(args)

    case System.find_executable("ab-av1") do
      nil ->
        Logger.error("ab-av1 executable not found")
        {:error, :not_found}

      path ->
        port =
          Port.open({:spawn_executable, path}, [
            :binary,
            :exit_status,
            :line,
            :use_stdio,
            :stderr_to_stdout,
            args: cleaned_args
          ])

        {:ok, port}
    end
  end

  @spec preprocess_input_file([String.t()]) :: {:ok, [String.t()]}
  defp preprocess_input_file(args) do
    # Find the input file path in the args
    case find_input_file_path(args) do
      {:ok, input_path, input_index} ->
        # Clean the input file of image attachments
        {:ok, cleaned_path} = clean_attachments(input_path)
        # Replace the input path in args with cleaned path
        new_args = List.replace_at(args, input_index, cleaned_path)
        {:ok, new_args}

      :not_found ->
        # No input file found in args, return as-is
        {:ok, args}
    end
  end

  @spec find_input_file_path([String.t()]) :: {:ok, String.t(), integer()} | :not_found
  defp find_input_file_path(args) do
    # Look for --input flag followed by file path
    case Enum.find_index(args, &(&1 == "--input")) do
      nil ->
        :not_found

      input_flag_index ->
        file_path_index = input_flag_index + 1

        if file_path_index < length(args) do
          file_path = Enum.at(args, file_path_index)
          {:ok, file_path, file_path_index}
        else
          :not_found
        end
    end
  end
end
