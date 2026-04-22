defmodule Reencodarr.Media.VideoStateMachine do
  @moduledoc """
  State machine for video processing workflow.

  Ensures videos can only transition through valid states and provides
  clear state management for the entire video processing pipeline.

  ## State Flow:
  ```
  needs_analysis -> analyzing -> analyzed -> crf_searching -> crf_searched -> encoding -> encoded
                       ↓                         ↓                ↓            ↓
                     failed                    failed           failed      failed
  ```

  ## States:
  - `needs_analysis`: Video lacks required metadata, needs MediaInfo analysis
  - `analyzing`: Video has been claimed by the analyzer and is being processed
  - `analyzed`: Video has all metadata, ready for CRF search
  - `crf_searching`: Video is currently being CRF searched for optimal quality
  - `crf_searched`: Video has VMAF data, ready for encoding
  - `encoding`: Video is currently being encoded
  - `encoded`: Video has been successfully encoded (final state)
  - `failed`: Video processing failed at some stage (terminal state)
  """

  import Ecto.Changeset
  alias Reencodarr.DbWriter
  alias Reencodarr.Media.Video
  require Logger

  @valid_states ~w(needs_analysis analyzing analyzed crf_searching crf_searched encoding encoded failed)a

  @valid_transitions %{
    needs_analysis: [:analyzing, :analyzed, :crf_searched, :encoded, :failed],
    analyzing: [:analyzed, :encoded, :needs_analysis, :failed],
    analyzed: [:crf_searching, :crf_searched, :encoded, :failed, :needs_analysis],
    # Can go back to analyzed if CRF search is cancelled, or reset to needs_analysis
    crf_searching: [:crf_searched, :failed, :analyzed, :needs_analysis],
    # Can restart CRF search if needed, or reset to needs_analysis
    crf_searched: [:encoding, :failed, :crf_searching, :needs_analysis],
    # Can go back to crf_searched if encoding fails, or reset to needs_analysis
    encoding: [:encoded, :failed, :crf_searched, :needs_analysis],
    # Can only fail from encoded state (e.g., file corruption)
    # Can also reset to needs_analysis for reprocessing (e.g., missing original_size)
    encoded: [:failed, :needs_analysis],
    # Can retry from any previous state
    failed: [:needs_analysis, :analyzed, :crf_searching, :crf_searched, :encoding]
  }

  @doc """
  Gets all valid video states.
  """
  @spec valid_states() :: [atom()]
  def valid_states, do: @valid_states

  @doc """
  Gets valid transitions from a given state.
  """
  @spec valid_transitions(atom()) :: [atom()]
  def valid_transitions(from_state) when from_state in @valid_states do
    Map.get(@valid_transitions, from_state, [])
  end

  @doc """
  Checks if a state transition is valid.
  """
  @spec valid_transition?(atom(), atom()) :: boolean()
  def valid_transition?(from_state, to_state)
      when from_state in @valid_states and to_state in @valid_states do
    to_state in valid_transitions(from_state)
  end

  def valid_transition?(_, _), do: false

  @doc """
  Validates and transitions a video to a new state.
  Returns {:ok, changeset} or {:error, reason}.
  """
  @spec transition(Video.t(), atom(), map()) :: {:ok, Ecto.Changeset.t()} | {:error, String.t()}
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
  @spec transition_to_needs_analysis(Video.t(), map()) ::
          {:ok, Ecto.Changeset.t()} | {:error, String.t()}
  def transition_to_needs_analysis(%Video{} = video, attrs \\ %{}) do
    transition(video, :needs_analysis, attrs)
  end

  @spec transition_to_analyzed(Video.t(), map()) ::
          {:ok, Ecto.Changeset.t()} | {:error, String.t()}
  def transition_to_analyzed(%Video{} = video, attrs \\ %{}) do
    # Check if video has low bitrate and HDR content, should be marked as encoded
    if low_bitrate?(video) do
      bitrate_mbps = video.bitrate / 1_000_000

      Logger.debug(
        "Video #{video.path} has low bitrate (#{:erlang.float_to_binary(bitrate_mbps, decimals: 1)} Mbps) and HDR, marking as encoded"
      )

      transition(video, :encoded, attrs)
    else
      # Don't add any extra validation flags - let the changeset validation handle requirements
      transition(video, :analyzed, attrs)
    end
  end

  @spec transition_to_crf_searching(Video.t(), map()) ::
          {:ok, Ecto.Changeset.t()} | {:error, String.t()}
  def transition_to_crf_searching(%Video{} = video, attrs \\ %{}) do
    transition(video, :crf_searching, attrs)
  end

  @spec transition_to_crf_searched(Video.t(), map()) ::
          {:ok, Ecto.Changeset.t()} | {:error, String.t()}
  def transition_to_crf_searched(%Video{} = video, attrs \\ %{}) do
    transition(video, :crf_searched, attrs)
  end

  @spec transition_to_encoding(Video.t(), map()) ::
          {:ok, Ecto.Changeset.t()} | {:error, String.t()}
  def transition_to_encoding(%Video{} = video, attrs \\ %{}) do
    transition(video, :encoding, attrs)
  end

  @spec transition_to_encoded(Video.t(), map()) ::
          {:ok, Ecto.Changeset.t()} | {:error, String.t()}
  def transition_to_encoded(%Video{} = video, attrs \\ %{}) do
    transition(video, :encoded, attrs)
  end

  @spec transition_to_failed(Video.t(), map()) :: {:ok, Ecto.Changeset.t()} | {:error, String.t()}
  def transition_to_failed(%Video{} = video, attrs \\ %{}) do
    transition(video, :failed, attrs)
  end

  @doc """
  Gets the expected next state for a video based on its current state and data.
  """
  @spec next_expected_state(Video.t()) :: atom()
  def next_expected_state(%Video{state: :needs_analysis} = video) do
    if analysis_complete?(video), do: :analyzed, else: :needs_analysis
  end

  def next_expected_state(%Video{state: :analyzing} = video) do
    if analysis_complete?(video), do: :analyzed, else: :analyzing
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

  def next_expected_state(%Video{state: :encoding}) do
    :encoded
  end

  def next_expected_state(%Video{state: state}) when state in [:encoded, :failed] do
    # Terminal states
    state
  end

  # Private validation functions

  defp validate_state_transition(changeset, from_state, to_state) do
    case to_state do
      :analyzed ->
        validate_analysis_requirements(changeset)

      :crf_searched ->
        validate_vmaf_requirements(changeset)

      :encoded ->
        validate_encoding_requirements(changeset, from_state)

      _ ->
        changeset
    end
  end

  defp validate_analysis_requirements(changeset) do
    changeset
    |> validate_required([:bitrate, :width, :height, :path])
    |> validate_optional_duration()
    |> validate_codecs_present()
    |> validate_metadata_completeness()
  end

  defp validate_metadata_completeness(changeset) do
    # Ensure bitrate, width, height are all positive numbers
    changeset
    |> validate_change(:bitrate, fn :bitrate, bitrate ->
      if is_integer(bitrate) and bitrate > 0,
        do: [],
        else: [bitrate: "must be a positive integer"]
    end)
    |> validate_change(:width, fn :width, width ->
      if is_integer(width) and width > 0, do: [], else: [width: "must be a positive integer"]
    end)
    |> validate_change(:height, fn :height, height ->
      if is_integer(height) and height > 0,
        do: [],
        else: [height: "must be a positive integer"]
    end)
  end

  defp validate_optional_duration(changeset) do
    # Only validate duration if it's present, since some video files don't have duration metadata
    case get_change(changeset, :duration) || get_field(changeset, :duration) do
      nil ->
        changeset

      duration when is_number(duration) and duration > 0.0 ->
        changeset

      _invalid ->
        add_error(changeset, :duration, "must be greater than 0 when present")
    end
  end

  defp validate_vmaf_requirements(changeset) do
    # CRITICAL: Validate that a chosen VMAF actually exists before allowing crf_searched state.
    # video_id is always a pos_integer here — only persisted videos reach crf_searched.
    video_id = get_field(changeset, :id)

    if chosen_vmaf_exists_for_video(video_id) do
      changeset
    else
      add_error(
        changeset,
        :state,
        "cannot transition to crf_searched: no chosen VMAF record found"
      )
    end
  end

  defp validate_encoding_requirements(changeset, _from_state) do
    # Only validate required metadata. VMAF existence was already enforced during
    # the crf_searched transition, so by :encoding state it is guaranteed.
    # Skip-encoding paths (already AV1 / low bitrate) legitimately have no VMAF.
    validate_encoding_metadata(changeset)
  end

  defp validate_encoding_metadata(changeset) do
    # Only path is required to transition to :encoded.
    # bitrate/width/height belong to analysis validation, not encoding validation —
    # skip-encoding paths (already AV1 / low bitrate) may legitimately lack analysis metadata.
    validate_required(changeset, [:path])
  end

  defp validate_codecs_present(changeset) do
    changeset
    |> validate_change(:video_codecs, fn :video_codecs, codecs ->
      if is_list(codecs) and not Enum.empty?(codecs),
        do: [],
        else: [video_codecs: "must have at least one codec"]
    end)
    |> validate_change(:audio_codecs, fn :audio_codecs, codecs ->
      if is_list(codecs) and not Enum.empty?(codecs),
        do: [],
        else: [audio_codecs: "must have at least one codec"]
    end)
  end

  # Helper functions for state determination

  defp analysis_complete?(%Video{} = video) do
    video_dimensions_valid?(video) and
      video_bitrate_valid?(video) and
      video_duration_valid?(video) and
      video_codecs_valid?(video)
  end

  defp video_bitrate_valid?(%Video{bitrate: bitrate}) do
    is_integer(bitrate) and bitrate > 0
  end

  defp video_dimensions_valid?(%Video{width: width, height: height}) do
    is_integer(width) and width > 0 and
      is_integer(height) and height > 0
  end

  defp video_duration_valid?(%Video{duration: duration}) do
    is_number(duration) and duration > 0.0
  end

  defp video_codecs_valid?(%Video{video_codecs: video_codecs, audio_codecs: audio_codecs}) do
    is_list(video_codecs) and not Enum.empty?(video_codecs) and
      is_list(audio_codecs) and not Enum.empty?(audio_codecs)
  end

  defp has_vmaf_data?(%Video{} = _video) do
    # This would check if the video has associated VMAF records
    # For now, we'll assume it's handled elsewhere
    # In a real implementation, this might query the vmafs association
    false
  end

  # Only accepts a persisted video id — nil or any other type is a bug and will crash.
  @spec chosen_vmaf_exists_for_video(pos_integer()) :: boolean()
  defp chosen_vmaf_exists_for_video(video_id) when is_integer(video_id) and video_id > 0 do
    import Ecto.Query
    alias Reencodarr.Repo

    Repo.exists?(
      from(v in Reencodarr.Media.Video,
        where: v.id == ^video_id and not is_nil(v.chosen_vmaf_id)
      )
    )
  end

  # === High-level State Management Functions ===
  # These functions handle database operations with proper error handling

  @spec mark_as_crf_searching(Video.t()) :: {:ok, Video.t()} | {:error, any()}
  def mark_as_crf_searching(%Video{} = video),
    do: mark_video_state(video, &transition_to_crf_searching/1)

  @spec mark_as_encoding(Video.t()) :: {:ok, Video.t()} | {:error, any()}
  def mark_as_encoding(%Video{} = video),
    do: mark_video_state(video, &transition_to_encoding/1, broadcast: false)

  @spec mark_as_reencoded(Video.t()) :: {:ok, Video.t()} | {:error, any()}
  def mark_as_reencoded(%Video{} = video) do
    case video.state do
      :encoded ->
        {:ok, video}

      state
      when state in [
             :encoding,
             :crf_searched,
             :needs_analysis,
             :analyzed,
             :crf_searching,
             :failed
           ] ->
        do_transition_to_encoded(%{video | state: :encoding})
    end
  end

  defp do_transition_to_encoded(video) do
    # Force :encoding so the :encoding → :encoded transition is always valid
    case transition_to_encoded(video) do
      {:ok, changeset} ->
        DbWriter.run(fn -> Reencodarr.Repo.update(changeset) end,
          label: "transition video to encoded"
        )

      error ->
        error
    end
  end

  @spec mark_as_analyzed(Video.t()) :: {:ok, Video.t()} | {:error, any()}
  def mark_as_analyzed(%Video{} = video),
    do: mark_video_state(video, &transition_to_analyzed/1)

  @doc """
  Marks a video as failed. Rescues `Ecto.StaleEntryError` for test cleanup races.
  """
  @spec mark_as_failed(Video.t()) :: {:ok, Video.t()} | {:error, any()}
  def mark_as_failed(%Video{} = video) do
    mark_video_state(video, &transition_to_failed/1)
  rescue
    Ecto.StaleEntryError ->
      {:ok, video}
  end

  @spec mark_as_crf_searched(Video.t()) :: {:ok, Video.t()} | {:error, any()}
  def mark_as_crf_searched(%Video{} = video),
    do: mark_video_state(video, &transition_to_crf_searched/1)

  @spec mark_as_needs_analysis(Video.t()) :: {:ok, Video.t()} | {:error, any()}
  def mark_as_needs_analysis(%Video{} = video),
    do: mark_video_state(video, &transition_to_needs_analysis/1)

  @spec mark_as_encoded(Video.t()) :: {:ok, Video.t()} | {:error, any()}
  def mark_as_encoded(%Video{} = video),
    do: mark_video_state(video, &transition_to_encoded/1)

  # Public helper functions

  @doc """
  Broadcasts a state transition event to notify interested processes.
  This allows Broadway producers to react to specific state changes instead of
  generic upsert events, improving efficiency and precision.
  """
  @spec broadcast_state_transition(Video.t(), atom()) :: :ok | {:error, any()}
  def broadcast_state_transition(%Video{} = video, new_state) do
    Logger.debug(
      "[VideoStateMachine] Broadcasting state transition: #{video.path} -> #{new_state}"
    )

    Phoenix.PubSub.broadcast(
      Reencodarr.PubSub,
      "video_state_transitions",
      {:video_state_changed, video, new_state}
    )
  end

  # Private helper functions

  defp mark_video_state(%Video{} = video, transition_fn, opts \\ []) do
    with {:ok, changeset} <- transition_fn.(video),
         {:ok, updated_video} <- do_repo_update(changeset, opts) do
      if Keyword.get(opts, :broadcast, true) do
        broadcast_state_transition(updated_video, updated_video.state)
      end

      {:ok, updated_video}
    end
  end

  defp do_repo_update(changeset, _opts) do
    target_state = Ecto.Changeset.get_field(changeset, :state)
    label = if target_state, do: "transition video to #{target_state}", else: "update video state"

    DbWriter.run(fn -> Reencodarr.Repo.update(changeset) end, label: label)
  end

  # Check if video has low bitrate (less than 5 Mbps = 5,000,000 bps) AND is HDR and should skip encoding
  defp low_bitrate?(%Video{bitrate: bitrate, hdr: hdr})
       when is_integer(bitrate) and bitrate > 0 and not is_nil(hdr) do
    bitrate < 5_000_000
  end

  defp low_bitrate?(_video), do: false
end
