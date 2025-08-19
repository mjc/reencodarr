defmodule Reencodarr.Media.VideoStateMachine do
  @moduledoc """
  State machine for video processing workflow.

  Ensures videos can only transition through valid states and provides
  clear state management for the entire video processing pipeline.

  ## State Flow:
  ```
  needs_analysis -> analyzed -> crf_searching -> crf_searched -> encoding -> encoded
                                     ↓                ↓            ↓
                                   failed           failed      failed
  ```

  ## States:
  - `needs_analysis`: Video lacks required metadata, needs MediaInfo analysis
  - `analyzed`: Video has all metadata, ready for CRF search
  - `crf_searching`: Video is currently being CRF searched for optimal quality
  - `crf_searched`: Video has VMAF data, ready for encoding
  - `encoding`: Video is currently being encoded
  - `encoded`: Video has been successfully encoded (final state)
  - `failed`: Video processing failed at some stage (terminal state)
  """

  import Ecto.Changeset
  alias Reencodarr.Media.Video

  @valid_states ~w(needs_analysis analyzed crf_searching crf_searched encoding encoded failed)a

  # Valid state transitions - only these transitions are allowed
  @valid_transitions %{
    needs_analysis: [:analyzed, :failed],
    analyzed: [:crf_searching, :failed],
    # Can go back to analyzed if CRF search is cancelled
    crf_searching: [:crf_searched, :failed, :analyzed],
    # Can restart CRF search if needed
    crf_searched: [:encoding, :failed, :crf_searching],
    # Can go back to crf_searched if encoding fails
    encoding: [:encoded, :failed, :crf_searched],
    # Can only fail from encoded state (e.g., file corruption)
    encoded: [:failed],
    # Can retry from any previous state
    failed: [:needs_analysis, :analyzed, :crf_searching, :crf_searched, :encoding]
  }

  @doc """
  Gets all valid video states.
  """
  def valid_states, do: @valid_states

  @doc """
  Gets valid transitions from a given state.
  """
  def valid_transitions(from_state) when from_state in @valid_states do
    Map.get(@valid_transitions, from_state, [])
  end

  @doc """
  Checks if a state transition is valid.
  """
  def valid_transition?(from_state, to_state)
      when from_state in @valid_states and to_state in @valid_states do
    to_state in valid_transitions(from_state)
  end

  def valid_transition?(_, _), do: false

  @doc """
  Validates and transitions a video to a new state.
  Returns {:ok, changeset} or {:error, reason}.
  """
  def transition(%Video{} = video, to_state, attrs \\ %{}) do
    from_state = video.state

    cond do
      to_state not in @valid_states ->
        {:error, "Invalid state: #{to_state}"}

      not valid_transition?(from_state, to_state) ->
        {:error, "Invalid transition from #{from_state} to #{to_state}"}

      true ->
        changeset =
          video
          |> change(attrs)
          |> put_change(:state, to_state)
          |> validate_state_transition(from_state, to_state)

        {:ok, changeset}
    end
  end

  @doc """
  Transitions a video to a new state with automatic state-specific validations.
  """
  def transition_to_analyzed(%Video{} = video, attrs \\ %{}) do
    attrs_with_validations =
      Map.merge(attrs, %{
        failed: false,
        # Ensure all analysis fields are present
        validate_analysis_complete: true
      })

    transition(video, :analyzed, attrs_with_validations)
  end

  def transition_to_crf_searching(%Video{} = video, attrs \\ %{}) do
    transition(video, :crf_searching, Map.put(attrs, :failed, false))
  end

  def transition_to_crf_searched(%Video{} = video, attrs \\ %{}) do
    transition(video, :crf_searched, Map.put(attrs, :failed, false))
  end

  def transition_to_encoding(%Video{} = video, attrs \\ %{}) do
    transition(video, :encoding, Map.put(attrs, :failed, false))
  end

  def transition_to_encoded(%Video{} = video, attrs \\ %{}) do
    attrs_with_completion =
      Map.merge(attrs, %{
        reencoded: true,
        failed: false
      })

    transition(video, :encoded, attrs_with_completion)
  end

  def transition_to_failed(%Video{} = video, attrs \\ %{}) do
    attrs_with_failure =
      Map.merge(attrs, %{
        failed: true
      })

    transition(video, :failed, attrs_with_failure)
  end

  @doc """
  Gets the expected next state for a video based on its current state and data.
  """
  def next_expected_state(%Video{state: :needs_analysis} = video) do
    if analysis_complete?(video), do: :analyzed, else: :needs_analysis
  end

  def next_expected_state(%Video{state: :analyzed}) do
    :crf_searching
  end

  def next_expected_state(%Video{state: :crf_searching} = video) do
    if has_vmaf_data?(video), do: :crf_searched, else: :crf_searching
  end

  def next_expected_state(%Video{state: :crf_searched}) do
    :encoding
  end

  def next_expected_state(%Video{state: :encoding} = video) do
    if video.reencoded, do: :encoded, else: :encoding
  end

  def next_expected_state(%Video{state: state}) when state in [:encoded, :failed] do
    # Terminal states
    state
  end

  # Private validation functions

  defp validate_state_transition(changeset, _from_state, to_state) do
    case to_state do
      :analyzed ->
        validate_analysis_requirements(changeset)

      :crf_searched ->
        validate_vmaf_requirements(changeset)

      :encoded ->
        validate_encoding_requirements(changeset)

      _ ->
        changeset
    end
  end

  defp validate_analysis_requirements(changeset) do
    changeset
    |> validate_required([:bitrate, :width, :height, :duration])
    |> validate_number(:duration, greater_than: 0.0)
    |> validate_codecs_present()
  end

  defp validate_vmaf_requirements(changeset) do
    # This would be validated in the context where VMAFs are checked
    changeset
  end

  defp validate_encoding_requirements(changeset) do
    changeset
    |> validate_change(:reencoded, fn :reencoded, reencoded ->
      if reencoded, do: [], else: [reencoded: "must be true for encoded state"]
    end)
  end

  defp validate_codecs_present(changeset) do
    video_codecs = get_field(changeset, :video_codecs)
    audio_codecs = get_field(changeset, :audio_codecs)
    audio_count = get_field(changeset, :audio_count)

    changeset =
      if is_nil(video_codecs) or Enum.empty?(video_codecs) do
        add_error(changeset, :video_codecs, "must be present for analyzed state")
      else
        changeset
      end

    # Audio validation: either has audio tracks OR is video-only (audio_count = 0)
    if (is_nil(audio_codecs) or Enum.empty?(audio_codecs)) and
         (is_nil(audio_count) or audio_count > 0) do
      add_error(changeset, :audio_codecs, "must be present for analyzed state unless video-only")
    else
      changeset
    end
  end

  # Helper functions for state checking

  defp analysis_complete?(%Video{} = video) do
    basic_metadata_present?(video) and
      video_codecs_present?(video) and
      audio_requirements_met?(video)
  end

  defp basic_metadata_present?(%Video{} = video) do
    not is_nil(video.bitrate) and
      not is_nil(video.width) and
      not is_nil(video.height) and
      not is_nil(video.duration) and
      video.duration > 0.0
  end

  defp video_codecs_present?(%Video{} = video) do
    not is_nil(video.video_codecs) and not Enum.empty?(video.video_codecs)
  end

  defp audio_requirements_met?(%Video{} = video) do
    # Either has audio tracks OR is video-only
    (not is_nil(video.audio_codecs) and not Enum.empty?(video.audio_codecs)) or
      video.audio_count == 0
  end

  defp has_vmaf_data?(%Video{}) do
    # This would need to be checked against the vmafs table
    # For now, return false - this should be implemented in the context
    false
  end

  @doc """
  Gets a human-readable description of a state.
  """
  def state_description(:needs_analysis), do: "Needs Analysis"
  def state_description(:analyzed), do: "Analyzed"
  def state_description(:crf_searching), do: "CRF Searching"
  def state_description(:crf_searched), do: "CRF Searched"
  def state_description(:encoding), do: "Encoding"
  def state_description(:encoded), do: "Encoded"
  def state_description(:failed), do: "Failed"
  def state_description(_), do: "Unknown"

  @doc """
  Gets the next logical state in the processing pipeline.
  """
  def next_processing_state(:needs_analysis), do: :analyzed
  def next_processing_state(:analyzed), do: :crf_searching
  def next_processing_state(:crf_searching), do: :crf_searched
  def next_processing_state(:crf_searched), do: :encoding
  def next_processing_state(:encoding), do: :encoded
  # Terminal
  def next_processing_state(:encoded), do: :encoded
  # Restart from beginning
  def next_processing_state(:failed), do: :needs_analysis
end
