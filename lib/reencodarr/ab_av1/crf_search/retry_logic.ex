defmodule Reencodarr.AbAv1.CrfSearch.RetryLogic do
  @moduledoc """
  Handles retry logic for CRF search operations.

  This module determines when and how to retry failed CRF searches,
  particularly with the --preset 6 fallback strategy.
  """

  alias Reencodarr.Media
  alias Reencodarr.{Media, Repo}

  require Logger

  @doc """
  Determines if a CRF search should be retried with --preset 6.

  Returns:
  - `:mark_failed` - Too many attempts or no records, mark video as failed
  - `:already_retried` - Already tried with preset 6, don't retry again
  - `{:retry, vmaf_records}` - Should retry with preset 6, returns existing records to clear
  """
  @spec should_retry_with_preset_6(integer()) ::
          :mark_failed | :already_retried | {:retry, list(Media.Vmaf.t())}
  def should_retry_with_preset_6(video_id) do
    import Ecto.Query

    # Get existing VMAF records for this video
    existing_vmafs =
      from(v in Media.Vmaf, where: v.video_id == ^video_id)
      |> Repo.all()

    case existing_vmafs do
      [] ->
        # No existing records, mark as failed (no point retrying with preset 6 if we haven't tried anything yet)
        :mark_failed

      vmafs ->
        # Check if any existing record was done with --preset 6
        has_preset_6 = Enum.any?(vmafs, &Media.vmaf_has_preset_6?/1)

        # Check if we have too many failed attempts (more than 3 VMAF records suggests multiple failures)
        cond do
          length(vmafs) > 3 -> :mark_failed
          has_preset_6 -> :already_retried
          true -> {:retry, vmafs}
        end
    end
  end

  @doc """
  Builds detailed error message for CRF search failures.
  """
  @spec build_detailed_error_message(integer(), [%{crf: float(), score: float()}], String.t()) ::
          String.t()
  def build_detailed_error_message(target_vmaf, tested_scores, video_path) do
    if Enum.empty?(tested_scores) do
      "CrfSearch: Failed to find a suitable CRF for #{video_path} - no VMAF scores were tested"
    else
      scores_text =
        Enum.map_join(tested_scores, ", ", fn %{crf: crf, score: score} ->
          "CRF #{crf}: #{score}"
        end)

      "CrfSearch: Failed to find a suitable CRF for #{video_path}. Target: #{target_vmaf}, tested scores: [#{scores_text}]"
    end
  end

  @doc """
  Processes CRF search error and determines retry strategy.
  """
  @spec handle_crf_search_error(Media.Video.t(), integer()) :: :ok
  def handle_crf_search_error(video, target_vmaf) do
    Logger.debug("CrfSearch: Processing error line for video #{video.id}")
    tested_scores = Media.get_vmaf_scores_for_video(video.id)

    error_msg = build_detailed_error_message(target_vmaf, tested_scores, video.path)
    Logger.error(error_msg)

    # Check if we should retry with --preset 6
    retry_result = should_retry_with_preset_6(video.id)

    case retry_result do
      :mark_failed ->
        Logger.warning(
          "CrfSearch: Marking video #{video.id} as failed after exhausting retry options"
        )

        Media.VideoStateMachine.mark_as_failed(video)

      :already_retried ->
        Logger.warning(
          "CrfSearch: Video #{video.id} already retried with preset 6, marking as failed"
        )

        Media.VideoStateMachine.mark_as_failed(video)

      {:retry, vmaf_records} ->
        vmaf_summary =
          Enum.map_join(vmaf_records, ", ", fn vmaf ->
            "CRF #{vmaf.crf}: #{vmaf.score} VMAF"
          end)

        Logger.info(
          "CrfSearch: Retrying video #{video.id} with --preset 6 (clearing #{length(vmaf_records)} existing VMAF records: #{vmaf_summary})"
        )

        Media.clear_vmaf_records(video.id, vmaf_records)

        # Trigger retry with preset 6
        GenServer.cast(
          Reencodarr.AbAv1.CrfSearch,
          {:crf_search_with_preset_6, video, target_vmaf}
        )
    end

    :ok
  end
end
