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
  Remove image attachments from MKV files to prevent FFmpeg encoding failures.

  Some MKV files contain attached JPEG/PNG images which cause FFmpeg to fail
  with exit code 218. This function uses mkvmerge to remove these attachments and streams.

  Always returns the path to use - either cleaned temp file or original if cleaning not needed/failed.
  """
  @spec clean_mkv_attachments(String.t()) :: {:ok, String.t()}
  def clean_mkv_attachments(file_path) do
    # Only process MKV files
    if String.ends_with?(file_path, [".mkv", ".MKV"]) do
      case check_for_image_attachments(file_path) do
        {:ok, false} ->
          # No image attachments found, use original file
          Logger.debug("No image attachments found in #{file_path}")
          {:ok, file_path}

        {:ok, true} ->
          # Image attachments found, clean them
          Logger.info("Image attachments found in #{file_path}, cleaning...")
          remove_image_attachments(file_path)

        {:error, reason} ->
          Logger.warning("Failed to check attachments for #{file_path}: #{inspect(reason)}")
          # If we can't check, assume no attachments and use original file
          {:ok, file_path}
      end
    else
      # Not an MKV file, no cleaning needed
      {:ok, file_path}
    end
  end

  @spec check_for_image_attachments(String.t()) :: {:ok, boolean()} | {:error, term()}
  defp check_for_image_attachments(file_path) do
    case System.cmd("mkvmerge", ["-i", file_path], stderr_to_stdout: true) do
      {output, 0} ->
        # Check for:
        # 1. Attachment info with image types
        # 2. Video streams that are attached pictures (mjpeg, png with "attached pic" flag)
        has_image_attachments =
          String.contains?(output, "attachment") and
            (String.contains?(output, "image/jpeg") or
               String.contains?(output, "image/jpg") or
               String.contains?(output, "image/png"))

        # Check for image streams (these appear as tracks in mkvmerge output)
        # Look for tracks that are likely cover art (small video tracks, mjpeg/png)
        has_image_streams =
          Regex.match?(~r/Track ID \d+: video \(MJPEG\)/i, output) or
            Regex.match?(~r/Track ID \d+: video \(PNG\)/i, output)

        {:ok, has_image_attachments or has_image_streams}

      {_output, _exit_code} ->
        {:error, :mkvmerge_failed}
    end
  end

  @spec remove_image_attachments(String.t()) :: {:ok, String.t()}
  defp remove_image_attachments(file_path) do
    # Create a cleaned copy in temp directory
    filename = Path.basename(file_path)
    name_without_ext = Path.rootname(filename)
    ext = Path.extname(filename)
    cleaned_path = Path.join(temp_dir(), "#{name_without_ext}_cleaned#{ext}")

    Logger.info("Removing image attachments and streams from #{file_path}")

    # Copy file to temp location first
    case File.cp(file_path, cleaned_path) do
      :ok ->
        # Use mkvpropedit to delete tracks and attachments in-place
        case remove_image_tracks_and_attachments(cleaned_path) do
          :ok ->
            Logger.info("Successfully cleaned image streams from #{file_path}")
            {:ok, cleaned_path}

          {:error, reason} ->
            Logger.warning(
              "Failed to clean #{file_path}: #{inspect(reason)}, falling back to original"
            )

            File.rm(cleaned_path)
            {:ok, file_path}
        end

      {:error, reason} ->
        Logger.warning("Failed to copy file for cleaning: #{inspect(reason)}")
        {:ok, file_path}
    end
  end

  defp remove_image_tracks_and_attachments(cleaned_path) do
    # Get track info to find image streams
    case get_image_track_uids(cleaned_path) do
      {:ok, track_uids} ->
        delete_tracks_and_attachments(cleaned_path, track_uids)

      {:error, reason} ->
        # If we can't get track info, at least try to delete attachments
        Logger.warning("Failed to get track info: #{inspect(reason)}, trying attachments only")
        delete_image_attachments(cleaned_path)
    end
  end

  defp delete_tracks_and_attachments(cleaned_path, track_uids) do
    # Delete each image track by UID using mkvpropedit
    result =
      Enum.reduce_while(track_uids, :ok, fn uid, _acc ->
        case System.cmd("mkvpropedit", [cleaned_path, "--delete-track", uid],
               stderr_to_stdout: true
             ) do
          {_output, 0} ->
            {:cont, :ok}

          {output, exit_code} ->
            Logger.warning(
              "mkvpropedit failed to delete track #{uid}: exit #{exit_code}, output: #{output}"
            )

            {:halt, {:error, :track_deletion_failed}}
        end
      end)

    # Also delete image attachments
    case result do
      :ok -> delete_image_attachments(cleaned_path)
      error -> error
    end
  end

  defp get_image_track_uids(file_path) do
    case System.cmd("mkvmerge", ["-J", file_path], stderr_to_stdout: true) do
      {output, 0} ->
        parse_image_tracks_from_json(output)

      {_output, _exit_code} ->
        {:error, :mkvmerge_failed}
    end
  end

  defp parse_image_tracks_from_json(output) do
    case Jason.decode(output) do
      {:ok, %{"tracks" => tracks}} ->
        image_uids = extract_image_track_uids(tracks)
        {:ok, image_uids}

      _ ->
        {:ok, []}
    end
  end

  defp extract_image_track_uids(tracks) do
    tracks
    |> Enum.filter(&filter_and_log_video_track/1)
    |> Enum.map(& &1["properties"]["uid"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
  end

  defp filter_and_log_video_track(track) do
    is_image = image_video_track?(track)

    if track["type"] == "video" do
      Logger.debug(
        "Video track: codec=#{inspect(track["codec"])}, codec_id=#{inspect(track["properties"]["codec_id"])}, uid=#{inspect(track["properties"]["uid"])}, is_image=#{is_image}"
      )
    end

    is_image
  end

  defp image_video_track?(track) do
    track["type"] == "video" and
      (String.upcase(track["codec"] || "") in ["MJPEG", "PNG"] or
         String.contains?(track["properties"]["codec_id"] || "", ["V_MS/VFW", "PNG"]))
  end

  defp delete_image_attachments(cleaned_path) do
    attachment_types = ["image/jpg", "image/jpeg", "image/png"]

    Logger.info("Attempting to delete image attachments from #{cleaned_path}")

    result =
      Enum.reduce_while(attachment_types, :ok, fn mime_type, _acc ->
        Logger.debug("Deleting attachments with mime-type: #{mime_type}")

        case System.cmd(
               "mkvpropedit",
               [cleaned_path, "--delete-attachment", "mime-type:#{mime_type}"],
               stderr_to_stdout: true
             ) do
          {output, 0} ->
            Logger.info("Successfully deleted #{mime_type} attachments: #{output}")
            {:cont, :ok}

          # Exit code 2 means "no attachments of this type found" - that's OK
          {output, 2} ->
            Logger.debug("No #{mime_type} attachments found: #{output}")
            {:cont, :ok}

          {output, exit_code} ->
            Logger.warning(
              "mkvpropedit failed for #{mime_type}: exit #{exit_code}, output: #{output}"
            )

            # Continue even if one type fails
            {:cont, :ok}
        end
      end)

    result
  end

  @spec open_port([binary()]) :: port() | :error
  def open_port(args) do
    # Preprocess input file to remove image streams/attachments
    {:ok, cleaned_args} = preprocess_input_file(args)

    case System.find_executable("ab-av1") do
      nil ->
        Logger.error("ab-av1 executable not found")
        :error

      path ->
        Port.open({:spawn_executable, path}, [
          :binary,
          :exit_status,
          :line,
          :use_stdio,
          :stderr_to_stdout,
          args: cleaned_args
        ])
    end
  end

  @spec preprocess_input_file([String.t()]) :: {:ok, [String.t()]}
  defp preprocess_input_file(args) do
    # Find the input file path in the args
    case find_input_file_path(args) do
      {:ok, input_path, input_index} ->
        # Clean the input file of image attachments
        {:ok, cleaned_path} = clean_mkv_attachments(input_path)
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
