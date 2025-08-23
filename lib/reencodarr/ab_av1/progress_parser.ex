defmodule Reencodarr.AbAv1.ProgressParser do
  @moduledoc """
  Centralized ab-av1 output processing for both encoding and CRF search operations.

  This module handles all ab-av1 output parsing by delegating to OutputParser for
  structured data extraction, then dispatching to appropriate handlers based on
  operation context (encoding vs CRF search).
  """

  alias Reencodarr.AbAv1.CrfSearch.RetryLogic
  alias Reencodarr.AbAv1.OutputParser
  alias Reencodarr.Formatters
  alias Reencodarr.{Media, Telemetry}

  require Logger

  @doc """
  Process a single line of ab-av1 output with operation context.

  ## Parameters
    - `line`: Raw output line from ab-av1
    - `state`: Operation state (encoding or CRF search context)

  ## Examples
      # Encoding context
      ProgressParser.process_line(line, %{video: video})

      # CRF search context
      ProgressParser.process_line(line, {video, args, target_vmaf})
  """
  def process_line(line, state) do
    context = determine_context(state)

    case OutputParser.parse_line(line) do
      {:ok, %{type: type, data: data}} ->
        handle_parsed_output(type, data, state, context)

      :ignore ->
        handle_unmatched_line(line, context, state)
    end
  end

  # Determine operation context from state structure
  defp determine_context(%{video: _video}), do: :encoding
  defp determine_context({_video, _args, _target_vmaf}), do: :crf_search

  # Dispatch to appropriate handlers based on type and context
  defp handle_parsed_output(type, data, state, context) do
    case context do
      :encoding -> handle_encoding_output(type, data, state)
      :crf_search -> handle_crf_search_output(type, data, state)
    end
  end

  # Handle encoding-specific output types
  defp handle_encoding_output(type, data, state) do
    case type do
      :encoding_start -> handle_encoding_start(data, state)
      :progress -> handle_encoding_progress(data, state)
      :file_progress -> handle_encoding_file_progress(data, state)
      :success -> handle_encoding_success(data, state)
      :warning -> handle_encoding_warning(data)
      _ -> Logger.debug("ProgressParser: Unhandled encoding line type: #{type}")
    end
  end

  # Handle CRF search-specific output types
  defp handle_crf_search_output(type, data, state) do
    case type do
      :encoding_sample ->
        handle_crf_encoding_sample(data, state)

      :eta_vmaf ->
        handle_crf_eta_vmaf(data, state)

      :progress ->
        handle_crf_progress(data, state)

      :success ->
        handle_crf_success(data, state)

      :warning ->
        handle_crf_warning(data)

      :vmaf_comparison ->
        handle_crf_vmaf_comparison(data)

      vmaf_type when vmaf_type in [:vmaf_result, :sample_vmaf, :dash_vmaf] ->
        handle_crf_vmaf_result(data, state)

      _ ->
        Logger.debug("ProgressParser: Unhandled crf_search line type: #{type}")
    end
  end

  # Handle lines that didn't match OutputParser patterns
  defp handle_unmatched_line(line, context, state) do
    # Check for custom error patterns not in OutputParser
    if line == "Error: Failed to find a suitable crf" and context == :crf_search do
      {video, _args, target_vmaf} = state
      RetryLogic.handle_crf_search_error(video, target_vmaf)
    else
      # Log unmatched progress-like lines for debugging
      if String.contains?(line, "%") do
        Logger.warning(
          "ProgressParser: Unmatched #{context} progress-like line: #{inspect(line)}"
        )
      else
        Logger.debug("ProgressParser: Ignoring #{context} line: #{line}")
      end
    end
  end

  # === Encoding Handlers ===

  defp handle_encoding_start(_data, state) do
    # Extract original filename from video path for metadata
    original_filename = Path.basename(state.video.path)

    Telemetry.emit_encoder_started(original_filename)
  end

  defp handle_encoding_progress(data, state) do
    Telemetry.emit_encoder_progress(%{
      filename: Path.basename(state.video.path),
      percent: data.progress,
      eta: format_eta(data.eta, data.eta_unit),
      fps: data.fps
    })
  end

  defp handle_encoding_file_progress(data, state) do
    # File progress format: "Encoded 2.5 GB (75%)"
    # Convert to similar format as regular progress but without fps/eta
    Telemetry.emit_encoder_progress(%{
      filename: Path.basename(state.video.path),
      percent: data.progress,
      size: data.size,
      size_unit: data.unit,
      # Default values for compatibility with existing telemetry format
      eta: "unknown",
      fps: 0.0
    })
  end

  defp handle_encoding_success(_data, state) do
    Logger.info("Encoding successful for file: #{state.video.path}")
    Telemetry.emit_encoder_completed()
  end

  defp handle_encoding_warning(data) do
    Logger.warning("Encoding: #{data.message}")
  end

  # === CRF Search Handlers ===

  defp handle_crf_encoding_sample(data, state) do
    {video, _args, _target_vmaf} = state

    Logger.debug(
      "CrfSearch: Encoding sample #{data.sample_num}/#{data.total_samples}: #{data.crf}"
    )

    broadcast_crf_progress(video.path, %{
      filename: video.path,
      crf: data.crf
    })
  end

  defp handle_crf_vmaf_result(data, state) do
    {video, args, _target_vmaf} = state
    Logger.debug("CrfSearch: CRF: #{data.crf}, VMAF: #{data.score}, Percent: #{data.percent}%")

    Media.upsert_crf_search_vmaf(
      %{
        "crf" => to_string(data.crf),
        "score" => to_string(data.score),
        "percent" => to_string(data.percent),
        "chosen" => "false"
      },
      video,
      args
    )
  end

  defp handle_crf_eta_vmaf(data, state) do
    {video, args, _target_vmaf} = state

    Logger.debug(
      "CrfSearch: CRF: #{data.crf}, VMAF: #{data.score}, size: #{data.size} #{data.unit}, Percent: #{data.percent}%, time: #{data.time} #{data.time_unit}"
    )

    # Check size limits
    max_file_size_bytes = 10 * 1024 * 1024 * 1024
    estimated_size_bytes = convert_size_to_bytes(data.size, data.unit)

    if estimated_size_bytes > max_file_size_bytes do
      Logger.warning(
        "CrfSearch: VMAF CRF #{Formatters.format_crf(data.crf)} estimated file size (#{Formatters.format_file_size(estimated_size_bytes)}) exceeds 10GB limit for video #{video.id}. Recording VMAF but may fail if chosen."
      )
    end

    Media.upsert_crf_search_vmaf(
      %{
        "crf" => to_string(data.crf),
        "score" => to_string(data.score),
        "percent" => to_string(data.percent),
        "chosen" => "true",
        "size" => format_size_value(data.size),
        "unit" => data.unit,
        "time" => to_string(data.time),
        "time_unit" => data.time_unit
      },
      video,
      args
    )

    check_vmaf_size_limit(video, data)
  end

  defp handle_crf_progress(data, state) do
    {video, _args, _target_vmaf} = state

    Logger.debug(
      "CrfSearch Progress: #{data.progress}%, #{Formatters.format_fps(data.fps)}, ETA: #{data.eta}"
    )

    broadcast_crf_progress(video.path, %{
      filename: video.path,
      percent: data.progress,
      eta: to_string(data.eta),
      fps: data.fps
    })
  end

  defp handle_crf_success(data, state) do
    {video, _args, _target_vmaf} = state
    Logger.debug("CrfSearch successful for CRF: #{data.crf}")

    Media.mark_vmaf_as_chosen(video.id, to_string(data.crf))

    case Media.get_vmaf_by_crf(video.id, to_string(data.crf)) do
      nil ->
        Logger.warning(
          "CrfSearch: Could not find VMAF record for chosen CRF #{data.crf} for video #{video.id}"
        )

      vmaf ->
        check_vmaf_size_limit(video, vmaf)
    end
  end

  defp handle_crf_warning(data) do
    Logger.warning("CrfSearch: #{data.message}")
  end

  defp handle_crf_vmaf_comparison(data) do
    Logger.debug("VMAF comparison: #{data.file1} vs #{data.file2}")
  end

  # === Helper Functions ===

  # Helper function to format size values consistently with decimal precision
  defp format_size_value(size) when is_integer(size), do: "#{size}.0"
  defp format_size_value(size), do: to_string(size)

  # Helper function to format ETA with time unit
  defp format_eta(eta, unit) when is_integer(eta) and is_binary(unit) do
    # Simply reconstruct as "#{eta} #{unit}s" to match original input format
    "#{eta} #{unit}s"
  end

  defp broadcast_crf_progress(_video_path, progress_data) do
    Telemetry.emit_crf_search_progress(progress_data)
  end

  defp convert_size_to_bytes(size, unit) when is_binary(size) and is_binary(unit) do
    case Float.parse(size) do
      {size_float, ""} ->
        multiplier = get_size_multiplier(String.downcase(unit))
        trunc(size_float * multiplier)

      _ ->
        0
    end
  end

  defp convert_size_to_bytes(size, unit) when is_number(size) and is_binary(unit) do
    convert_size_to_bytes(to_string(size), unit)
  end

  defp convert_size_to_bytes(_, _), do: 0

  defp get_size_multiplier(unit_lower) do
    case unit_lower do
      "b" -> 1
      "kb" -> 1024
      "mb" -> 1024 * 1024
      "gb" -> 1024 * 1024 * 1024
      "tb" -> 1024 * 1024 * 1024 * 1024
      "mib" -> 1024 * 1024
      "gib" -> 1024 * 1024 * 1024
      _ -> 1
    end
  end

  defp check_vmaf_size_limit(video, vmaf) do
    case vmaf do
      %{size: size_string} when is_binary(size_string) ->
        check_parsed_size(video, vmaf, size_string)

      _ ->
        :ok
    end
  end

  defp check_parsed_size(video, vmaf, size_string) do
    case parse_size_string(size_string) do
      {:ok, size_bytes} ->
        check_size_against_limit(video, vmaf, size_bytes)

      :error ->
        Logger.warning("CrfSearch: Could not parse size string: #{size_string}")
        :ok
    end
  end

  defp check_size_against_limit(video, vmaf, size_bytes) do
    max_file_size_bytes = 10 * 1024 * 1024 * 1024

    if size_bytes > max_file_size_bytes do
      Logger.warning(
        "CrfSearch: Estimated size #{Formatters.format_file_size(size_bytes)} for video #{video.id} exceeds 10GB limit"
      )

      handle_size_limit_exceeded(video, vmaf.crf)
    else
      :ok
    end
  end

  defp parse_size_string(size_string) when is_binary(size_string) do
    case Regex.run(~r/^(\d+\.?\d*)\s*(\w+)$/i, String.trim(size_string)) do
      [_, size_value, unit] ->
        case Float.parse(size_value) do
          {size_float, ""} ->
            bytes = convert_size_to_bytes(size_float, unit)
            {:ok, bytes}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp parse_size_string(_), do: :error

  defp handle_size_limit_exceeded(video, crf) do
    Logger.error(
      "CrfSearch: Chosen VMAF CRF #{crf} exceeds 10GB limit for video #{video.id}. Marking as failed."
    )

    Reencodarr.FailureTracker.record_size_limit_failure(video, "Estimated > 10GB", "10GB",
      context: %{chosen_crf: crf}
    )

    Phoenix.PubSub.broadcast(
      Reencodarr.PubSub,
      "crf_search_events",
      {:crf_search_completed, video.id, {:error, :file_size_too_large}}
    )
  end
end
