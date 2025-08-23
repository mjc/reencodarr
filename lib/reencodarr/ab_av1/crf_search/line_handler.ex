defmodule Reencodarr.AbAv1.CrfSearch.LineHandler do
  @moduledoc """
  Handles processed output lines from ab-av1 during CRF search operations.

  This module contains the business logic for responding to different types
  of parsed output from the ab-av1 tool during CRF search.
  """

  alias Reencodarr.{Formatters, Media}
  alias Reencodarr.Statistics.CrfSearchProgress

  require Logger

  # Constants
  @max_file_size_bytes 10 * 1024 * 1024 * 1024

  @doc """
  Handles a parsed line based on its type and data.
  """
  @spec handle_parsed_line(atom(), map(), Media.Video.t(), list(), integer()) :: :ok
  def handle_parsed_line(type, data, video, args, _target_vmaf) do
    case type do
      :encoding_sample ->
        handle_encoding_sample(data, video)

      vmaf_type when vmaf_type in [:vmaf_result, :sample_vmaf, :dash_vmaf] ->
        handle_vmaf_result(data, video, args)

      :eta_vmaf ->
        handle_eta_vmaf(data, video, args)

      :progress ->
        handle_progress(data, video)

      :success ->
        handle_success(data, video)

      :warning ->
        handle_warning(data)

      :vmaf_comparison ->
        handle_vmaf_comparison(data)

      _ ->
        Logger.debug("CrfSearch: Unhandled output type: #{type}")
        :ok
    end
  end

  # Private handler functions

  defp handle_encoding_sample(data, video) do
    Logger.debug(
      "CrfSearch: Encoding sample #{data.sample_num}/#{data.total_samples}: #{data.crf}"
    )

    broadcast_crf_search_progress(video.path, %CrfSearchProgress{
      filename: video.path,
      crf: data.crf
    })
  end

  defp handle_vmaf_result(data, video, args) do
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

  defp handle_eta_vmaf(data, video, args) do
    Logger.info(
      "CrfSearch: CRF #{Formatters.format_crf(data.crf)} score #{Formatters.format_vmaf_score(data.score)}, estimated file size #{data.size} #{data.unit} (#{data.percent}%)"
    )

    # Check size limits before upserting
    estimated_size_bytes = convert_size_to_bytes(data.size, data.unit)

    if estimated_size_bytes > @max_file_size_bytes do
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
        "size" => to_string(data.size),
        "unit" => data.unit,
        "time" => to_string(data.time),
        "time_unit" => data.time_unit
      },
      video,
      args
    )
  end

  defp handle_progress(data, video) do
    Logger.debug("CrfSearch: Progress update for video #{video.id}: #{data}")

    case Media.get_vmaf_by_crf(video.id, to_string(data.crf)) do
      nil ->
        Logger.debug("CrfSearch: No VMAF found for CRF #{data.crf}")

      vmaf ->
        handle_vmaf_size_check(vmaf, video, data.crf)
    end
  end

  defp handle_success(data, video) do
    Logger.info("CrfSearch: Successfully completed for video #{video.id}, CRF: #{data.crf}")

    broadcast_crf_search_progress(video.path, %CrfSearchProgress{
      filename: video.path,
      crf: data.crf
    })
  end

  defp handle_warning(data) do
    Logger.warning("CrfSearch: #{data.message}")
  end

  defp handle_vmaf_comparison(data) do
    Logger.debug("CrfSearch: VMAF comparison: #{data.file1} vs #{data.file2}")
  end

  defp handle_vmaf_size_check(vmaf, video, crf) do
    case check_vmaf_size_limit(vmaf, video) do
      :ok ->
        :ok

      {:error, :size_too_large} ->
        handle_size_limit_exceeded(video, crf)
    end
  end

  defp handle_size_limit_exceeded(video, crf) do
    Logger.error(
      "CrfSearch: Video #{video.id} (#{Path.basename(video.path)}) with CRF #{crf} exceeds size limit. Marked as failed."
    )

    Reencodarr.FailureTracker.record_size_limit_failure(video, crf, @max_file_size_bytes)
  end

  # Helper functions

  defp check_vmaf_size_limit(vmaf, video) do
    case vmaf.size do
      nil ->
        :ok

      size_string when is_binary(size_string) ->
        validate_size_string(size_string, video)

      _ ->
        :ok
    end
  end

  defp validate_size_string(size_string, video) do
    case parse_size_string(size_string) do
      {:ok, size_bytes} ->
        validate_size_bytes(size_bytes, video)

      :error ->
        Logger.warning("CrfSearch: Could not parse size string: #{size_string}")
        :ok
    end
  end

  defp validate_size_bytes(size_bytes, video) do
    if size_bytes > @max_file_size_bytes do
      Logger.warning(
        "CrfSearch: Estimated size #{Formatters.format_file_size(size_bytes)} for video #{video.id} exceeds 10GB limit"
      )

      {:error, :size_too_large}
    else
      :ok
    end
  end

  defp parse_size_string(size_string) do
    case String.split(size_string, " ", parts: 2) do
      [size_str, unit] ->
        case Float.parse(size_str) do
          {size, _} -> {:ok, convert_size_to_bytes(size, unit)}
          :error -> :error
        end

      _ ->
        :error
    end
  end

  defp convert_size_to_bytes(size, unit) when is_binary(unit) do
    case String.downcase(unit) do
      "b" -> round(size)
      "kb" -> round(size * 1024)
      "mb" -> round(size * 1024 * 1024)
      "gb" -> round(size * 1024 * 1024 * 1024)
      "tb" -> round(size * 1024 * 1024 * 1024 * 1024)
      _ -> round(size)
    end
  end

  defp convert_size_to_bytes(size, _), do: round(size)

  defp broadcast_crf_search_progress(filename, progress) do
    video_filename = Path.basename(filename)

    updated_progress = %{progress | filename: video_filename}

    Phoenix.PubSub.broadcast(
      Reencodarr.PubSub,
      "crf_search_events",
      %{progress: updated_progress}
    )
  end
end
