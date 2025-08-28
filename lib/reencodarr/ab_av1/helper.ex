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
      File.mkdir_p!(temp_dir)
      temp_dir
    end
  end

  @doc """
  Remove image attachments from MKV files to prevent FFmpeg encoding failures.

  Some MKV files contain attached JPEG/PNG images which cause FFmpeg to fail
  with exit code 218. This function uses mkvpropedit to remove these attachments.

  Returns the cleaned file path (either original if no cleaning needed, or temp copy).
  """
  @spec clean_mkv_attachments(String.t()) :: {:ok, String.t()} | {:error, term()}
  def clean_mkv_attachments(file_path) do
    # Only process MKV files
    if Path.extname(file_path) |> String.downcase() == ".mkv" do
      case check_for_image_attachments(file_path) do
        {:ok, false} ->
          # No image attachments found, use original file
          {:ok, file_path}

        {:ok, true} ->
          # Image attachments found, clean them
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
        # Check if output contains attachment info with image types
        has_images =
          String.contains?(output, "attachment") and
            (String.contains?(output, "image/jpeg") or
               String.contains?(output, "image/jpg") or
               String.contains?(output, "image/png"))

        {:ok, has_images}

      {_output, _exit_code} ->
        {:error, :mkvmerge_failed}
    end
  end

  @spec remove_image_attachments(String.t()) :: {:ok, String.t()} | {:error, term()}
  defp remove_image_attachments(file_path) do
    # Create a cleaned copy in temp directory
    filename = Path.basename(file_path)
    name_without_ext = Path.rootname(filename)
    ext = Path.extname(filename)
    cleaned_path = Path.join(temp_dir(), "#{name_without_ext}_cleaned#{ext}")

    Logger.info("Removing image attachments from #{file_path}")

    # Copy original file to temp location
    case File.cp(file_path, cleaned_path) do
      :ok ->
        process_attachment_removal(file_path, cleaned_path)

      {:error, reason} ->
        Logger.error("Failed to copy file for cleaning: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp process_attachment_removal(original_path, cleaned_path) do
    attachment_types = ["image/jpg", "image/jpeg", "image/png"]

    success = Enum.all?(attachment_types, &remove_attachment_type(&1, cleaned_path))

    if success do
      Logger.info("Successfully cleaned image attachments from #{original_path}")
      {:ok, cleaned_path}
    else
      # If cleaning failed, fall back to original file
      File.rm(cleaned_path)
      Logger.warning("Failed to clean attachments, using original file: #{original_path}")
      {:ok, original_path}
    end
  end

  defp remove_attachment_type(mime_type, cleaned_path) do
    case System.cmd(
           "mkvpropedit",
           ["--delete-attachment", "mime-type:#{mime_type}", cleaned_path],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        true

      # Exit code 2 means "no attachments of this type found" - that's OK
      {_output, 2} ->
        true

      {output, exit_code} ->
        Logger.warning(
          "mkvpropedit failed for #{mime_type} on #{cleaned_path}: exit #{exit_code}, output: #{output}"
        )

        # Continue with other types even if one fails
        true
    end
  end

  @spec open_port([binary()]) :: port() | :error
  def open_port(args) do
    # Check if this is an encoding operation that needs input file cleaning
    cleaned_args =
      case preprocess_input_file(args) do
        {:ok, new_args} -> new_args
        # Fall back to original args if preprocessing fails
        {:error, _reason} -> args
      end

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

  @spec preprocess_input_file([String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  defp preprocess_input_file(args) do
    # Find the input file path in the args
    case find_input_file_path(args) do
      {:ok, input_path, input_index} ->
        # Clean the input file of image attachments
        case clean_mkv_attachments(input_path) do
          {:ok, cleaned_path} ->
            # Replace the input path in args with cleaned path
            new_args = List.replace_at(args, input_index, cleaned_path)
            {:ok, new_args}

          {:error, reason} ->
            {:error, reason}
        end

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
