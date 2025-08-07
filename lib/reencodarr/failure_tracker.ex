defmodule Reencodarr.FailureTracker do
  alias Reencodarr.Media

  @moduledoc """
  Centralized failure tracking for the video processing pipeline.

  Provides convenience functions to record failures with appropriate
  categories and context across different processing stages.
  """

  @doc """
  Enhanced failure recording with command and output capture for ab-av1 failures.

  When calling failure recording functions, you can include additional context:
  - `command`: The full ab-av1 command that was executed
  - `full_output`: Complete stdout/stderr from the command
  - `args`: The arguments passed to ab-av1
  """

  # Analysis stage failures
  def record_file_access_failure(video, reason, opts \\ []) do
    context = Map.merge(%{reason: reason}, Keyword.get(opts, :context, %{}))

    Media.record_video_failure(video, :analysis, :file_access,
      code: "FILE_ACCESS",
      message: "File access failed: #{reason}",
      context: context
    )
  end

  def record_mediainfo_failure(video, error, opts \\ []) do
    context = Map.merge(%{error: error}, Keyword.get(opts, :context, %{}))

    Media.record_video_failure(video, :analysis, :mediainfo_parsing,
      code: "MEDIAINFO_PARSE",
      message: "MediaInfo parsing failed: #{error}",
      context: context
    )
  end

  def record_validation_failure(video, changeset_errors, opts \\ []) do
    error_summary =
      Enum.map_join(changeset_errors, ", ", fn {field, {msg, _}} -> "#{field}: #{msg}" end)

    context = Map.merge(%{changeset_errors: changeset_errors}, Keyword.get(opts, :context, %{}))

    Media.record_video_failure(video, :analysis, :validation,
      code: "VALIDATION",
      message: "Validation failed: #{error_summary}",
      context: context
    )
  end

  # CRF search stage failures
  def record_vmaf_calculation_failure(video, reason, opts \\ []) do
    context = Map.merge(%{reason: reason}, Keyword.get(opts, :context, %{}))

    Media.record_video_failure(video, :crf_search, :vmaf_calculation,
      code: "VMAF_CALC",
      message: "VMAF calculation failed: #{reason}",
      context: context
    )
  end

  def record_crf_optimization_failure(video, target_vmaf, tested_scores \\ [], opts \\ []) do
    # Convert tuples to maps for JSON serialization
    serializable_scores =
      Enum.map(tested_scores, fn
        {crf, score} -> %{crf: crf, score: score}
        other -> other
      end)

    context =
      %{
        target_vmaf: target_vmaf,
        tested_scores: serializable_scores,
        score_count: length(tested_scores)
      }
      |> Map.merge(Keyword.get(opts, :context, %{}))

    Media.record_video_failure(video, :crf_search, :crf_optimization,
      code: "CRF_NOT_FOUND",
      message: "Failed to find suitable CRF for target VMAF #{target_vmaf}",
      context: context
    )
  end

  def record_size_limit_failure(video, estimated_size, limit \\ "10GB", opts \\ []) do
    context =
      %{
        estimated_size: estimated_size,
        size_limit: limit
      }
      |> Map.merge(Keyword.get(opts, :context, %{}))

    Media.record_video_failure(video, :crf_search, :size_limits,
      code: "SIZE_LIMIT",
      message: "Estimated file size #{estimated_size} exceeds #{limit} limit",
      context: context
    )
  end

  def record_preset_retry_failure(video, preset, retry_count \\ 1, opts \\ []) do
    context =
      %{
        preset: preset,
        retry_count: retry_count
      }
      |> Map.merge(Keyword.get(opts, :context, %{}))

    Media.record_video_failure(video, :crf_search, :preset_retry,
      code: "PRESET_RETRY",
      message: "CRF search failed even with preset #{preset} retry",
      context: context,
      retry_count: retry_count
    )
  end

  # Encoding stage failures
  def record_process_failure(video, exit_code, opts \\ []) do
    context = Keyword.get(opts, :context, %{})

    # Check if we can extract more specific FFmpeg error information from output
    {actual_exit_code, category, enhanced_message} =
      parse_ffmpeg_error_from_output(context, exit_code)

    enhanced_context =
      %{
        original_exit_code: exit_code,
        parsed_exit_code: actual_exit_code,
        classification: category
      }
      |> Map.merge(context)

    Media.record_video_failure(video, :encoding, category,
      code: "EXIT_#{actual_exit_code}",
      message: enhanced_message,
      context: enhanced_context
    )
  end

  def record_resource_exhaustion_failure(video, resource_type, details, opts \\ []) do
    context =
      %{
        resource_type: resource_type,
        details: details
      }
      |> Map.merge(Keyword.get(opts, :context, %{}))

    Media.record_video_failure(video, :encoding, :resource_exhaustion,
      code: "RESOURCE_#{String.upcase(to_string(resource_type))}",
      message: "Resource exhaustion: #{resource_type} - #{details}",
      context: context
    )
  end

  def record_timeout_failure(video, timeout_duration, opts \\ []) do
    context =
      %{
        timeout_duration: timeout_duration
      }
      |> Map.merge(Keyword.get(opts, :context, %{}))

    Media.record_video_failure(video, :encoding, :timeout,
      code: "TIMEOUT",
      message: "Encoding timeout after #{timeout_duration}",
      context: context
    )
  end

  def record_codec_failure(video, codec_info, opts \\ []) do
    context = Map.merge(%{codec_info: codec_info}, Keyword.get(opts, :context, %{}))

    Media.record_video_failure(video, :encoding, :codec_issues,
      code: "CODEC_UNSUPPORTED",
      message: "Codec compatibility issue: #{inspect(codec_info)}",
      context: context
    )
  end

  # Post-processing stage failures
  def record_file_operation_failure(video, operation, source, destination, error, opts \\ []) do
    context =
      %{
        operation: operation,
        source: source,
        destination: destination,
        error: error
      }
      |> Map.merge(Keyword.get(opts, :context, %{}))

    Media.record_video_failure(video, :post_process, :file_operations,
      code: "FILE_OP_#{String.upcase(to_string(operation))}",
      message: "File #{operation} failed from #{source} to #{destination}: #{error}",
      context: context
    )
  end

  def record_sync_failure(video, service, error, opts \\ []) do
    context =
      %{
        service: service,
        error: error
      }
      |> Map.merge(Keyword.get(opts, :context, %{}))

    Media.record_video_failure(video, :post_process, :sync_integration,
      code: "SYNC_#{String.upcase(to_string(service))}",
      message: "#{service} sync failed: #{error}",
      context: context
    )
  end

  def record_cleanup_failure(video, cleanup_target, error, opts \\ []) do
    context =
      %{
        cleanup_target: cleanup_target,
        error: error
      }
      |> Map.merge(Keyword.get(opts, :context, %{}))

    Media.record_video_failure(video, :post_process, :cleanup,
      code: "CLEANUP",
      message: "Cleanup failed for #{cleanup_target}: #{error}",
      context: context
    )
  end

  # Cross-cutting failures
  def record_configuration_failure(video, config_issue, opts \\ []) do
    context = Map.merge(%{config_issue: config_issue}, Keyword.get(opts, :context, %{}))

    # Determine most appropriate stage based on context
    stage = Keyword.get(opts, :stage, :analysis)

    Media.record_video_failure(video, stage, :configuration,
      code: "CONFIG",
      message: "Configuration issue: #{config_issue}",
      context: context
    )
  end

  def record_system_environment_failure(video, env_issue, opts \\ []) do
    context = Map.merge(%{env_issue: env_issue}, Keyword.get(opts, :context, %{}))

    stage = Keyword.get(opts, :stage, :analysis)

    Media.record_video_failure(video, stage, :system_environment,
      code: "ENV",
      message: "System environment issue: #{env_issue}",
      context: context
    )
  end

  def record_unknown_failure(video, stage, error, opts \\ []) do
    context = Map.merge(%{error: error}, Keyword.get(opts, :context, %{}))

    Media.record_video_failure(video, stage, :unknown,
      code: "UNKNOWN",
      message: "Unknown failure: #{inspect(error)}",
      context: context
    )
  end

  @doc """
  Parse FFmpeg errors from ab-av1 output to get more specific error information.

  Returns {actual_exit_code, category, message} where:
  - actual_exit_code: The real FFmpeg exit code (if found) or original exit code
  - category: The appropriate failure category based on the error
  - message: Enhanced error message with specific details
  """
  def parse_ffmpeg_error_from_output(context, original_exit_code) do
    output = Map.get(context, "full_output", "")

    if ffmpeg_exit_code = extract_ffmpeg_exit_code(output) do
      # FFmpeg exit code pattern: "Error: ffmpeg encode exit code 234"
      {category, base_message} = classify_encoding_exit_code(ffmpeg_exit_code)

      enhanced_message =
        enhance_message_with_ffmpeg_details(output, base_message, ffmpeg_exit_code)

      {ffmpeg_exit_code, category, enhanced_message}
    else
      # No specific FFmpeg error found, use original classification
      {category, message} = classify_encoding_exit_code(original_exit_code)
      {original_exit_code, category, message}
    end
  end

  defp extract_ffmpeg_exit_code(output) do
    case Regex.run(~r/Error: ffmpeg encode exit code (\d+)/, output) do
      [_, exit_code_str] -> String.to_integer(exit_code_str)
      _ -> nil
    end
  end

  defp enhance_message_with_ffmpeg_details(output, base_message, ffmpeg_exit_code) do
    specific_errors = extract_specific_ffmpeg_errors(output)

    if length(specific_errors) > 0 do
      error_details = Enum.join(specific_errors, "; ")
      "#{base_message} (FFmpeg exit #{ffmpeg_exit_code}): #{error_details}"
    else
      "#{base_message} (FFmpeg exit #{ffmpeg_exit_code})"
    end
  end

  defp extract_specific_ffmpeg_errors(output) do
    [
      # Channel layout errors
      ~r/Invalid channel layout .+ for specified mapping family/,
      # Codec errors
      ~r/Error while opening encoder - maybe incorrect parameters/,
      # Stream mapping errors
      ~r/Output with label .+ does not exist/,
      # Format errors
      ~r/Unknown encoder/,
      ~r/Encoder .+ not found/,
      # Resource errors
      ~r/Cannot allocate memory/,
      ~r/No space left on device/
    ]
    |> Enum.flat_map(fn regex ->
      case Regex.run(regex, output) do
        [match] -> [String.trim(match)]
        _ -> []
      end
    end)
  end

  @doc """
  Build enhanced context for ab-av1 command failures.

  ## Examples
      context = build_command_context(["crf-search", "--vmaf", "95", "input.mkv"],
                                     output_lines, %{target_vmaf: 95})
  """
  def build_command_context(args, output_lines \\ [], extra_context \\ %{}) do
    command_line = "ab-av1 " <> Enum.join(args, " ")

    full_output =
      case output_lines do
        lines when is_list(lines) -> Enum.join(lines, "\n")
        output when is_binary(output) -> output
        _ -> ""
      end

    %{
      command: command_line,
      args: args,
      full_output: full_output
    }
    |> Map.merge(extra_context)
  end

  # Private helper to classify encoding exit codes
  defp classify_encoding_exit_code(exit_code) do
    cond do
      resource_exhaustion_error?(exit_code) ->
        classify_resource_exhaustion_error(exit_code)

      system_environment_error?(exit_code) ->
        classify_system_environment_error(exit_code)

      configuration_error?(exit_code) ->
        {:configuration, "Invalid command line arguments - configuration error"}

      codec_error?(exit_code) ->
        classify_codec_error(exit_code)

      special_atom_code?(exit_code) ->
        classify_special_atom_code(exit_code)

      exit_code == 1 ->
        {:process_failure, "Standard encoding failure (corrupted/invalid input)"}

      true ->
        {:process_failure, "Unknown exit code: #{exit_code}"}
    end
  end

  defp resource_exhaustion_error?(exit_code) do
    exit_code in [137, 143, 28]
  end

  defp classify_resource_exhaustion_error(exit_code) do
    case exit_code do
      137 -> {:resource_exhaustion, "Process killed by system (likely OOM)"}
      143 -> {:resource_exhaustion, "Process terminated by SIGTERM"}
      28 -> {:resource_exhaustion, "No space left on device"}
    end
  end

  defp system_environment_error?(exit_code) do
    exit_code in [13, 5, 110]
  end

  defp classify_system_environment_error(exit_code) do
    case exit_code do
      13 -> {:system_environment, "Permission denied - check file system permissions"}
      5 -> {:system_environment, "I/O error - possible hardware issue"}
      110 -> {:system_environment, "Network timeout - systemic network connectivity issue"}
    end
  end

  defp configuration_error?(exit_code) do
    exit_code == 2
  end

  defp codec_error?(exit_code) do
    exit_code in [22, 69, 234]
  end

  defp classify_codec_error(exit_code) do
    case exit_code do
      22 -> {:codec_issues, "Invalid file format"}
      69 -> {:codec_issues, "Unsupported codec or format"}
      234 -> {:codec_issues, "Audio channel layout or codec conversion error"}
    end
  end

  defp special_atom_code?(exit_code) do
    exit_code in [:port_error, :timeout, :exception]
  end

  defp classify_special_atom_code(exit_code) do
    case exit_code do
      :port_error -> {:system_environment, "Failed to create encoding process"}
      :timeout -> {:timeout, "Encoding timeout - system may be overloaded"}
      :exception -> {:process_failure, "Unexpected exception during encoding"}
    end
  end
end
