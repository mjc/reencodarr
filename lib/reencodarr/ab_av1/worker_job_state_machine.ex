defmodule Reencodarr.AbAv1.WorkerJobStateMachine do
  @moduledoc """
  State machine for one connected worker's current job phase.
  """

  require Logger

  @type phase :: :idle | :receiving_input | :crf_searching

  @valid_phases [:idle, :receiving_input, :crf_searching]

  @valid_transitions %{
    idle: [:receiving_input, :crf_searching],
    receiving_input: [:receiving_input, :crf_searching, :idle],
    crf_searching: [:crf_searching, :receiving_input, :idle]
  }

  @spec valid_phases() :: [phase()]
  def valid_phases, do: @valid_phases

  @spec valid_transition?(phase(), phase()) :: boolean()
  def valid_transition?(from_phase, to_phase)
      when from_phase in @valid_phases and to_phase in @valid_phases do
    to_phase == from_phase or to_phase in Map.fetch!(@valid_transitions, from_phase)
  end

  def valid_transition?(_from_phase, _to_phase), do: false

  def transition(session, to_phase, attrs \\ %{})

  @spec transition(map(), phase(), map()) :: {:ok, map()} | {:error, :invalid_worker_phase}
  def transition(session, to_phase, attrs) when to_phase in @valid_phases do
    from_phase = Map.get(session, :phase, :idle)

    if valid_transition?(from_phase, to_phase) do
      {:ok, session |> Map.merge(attrs) |> Map.put(:phase, to_phase)}
    else
      Logger.warning("Invalid worker job transition from #{from_phase} to #{to_phase}")
      {:error, :invalid_worker_phase}
    end
  end

  def transition(_session, _to_phase, _attrs), do: {:error, :invalid_worker_phase}

  @spec assign_video(map(), integer(), phase()) :: {:ok, map()} | {:error, :invalid_worker_phase}
  def assign_video(session, video_id, phase) when is_integer(video_id) do
    transition(session, phase, %{
      active_video_id: video_id,
      transfer_progress: nil,
      crf_search_progress: nil
    })
  end

  @spec clear_video(map()) :: {:ok, map()}
  def clear_video(session) do
    {:ok,
     %{session | active_video_id: nil, transfer_progress: nil, crf_search_progress: nil}
     |> Map.put(:phase, :idle)}
  end

  @spec set_transfer_progress(map(), map()) :: {:ok, map()} | {:error, :invalid_worker_phase}
  def set_transfer_progress(session, progress) do
    transition(session, :receiving_input, %{
      active_video_id: Map.get(progress, :video_id, session.active_video_id),
      transfer_progress: progress,
      crf_search_progress: nil
    })
  end

  @spec finish_transfer(map()) :: {:ok, map()}
  def finish_transfer(%{active_video_id: nil} = session), do: clear_video(session)

  def finish_transfer(session) do
    {:ok, %{session | phase: :crf_searching, transfer_progress: nil}}
  end

  @spec set_crf_search_progress(map(), map()) :: {:ok, map()} | {:error, :invalid_worker_phase}
  def set_crf_search_progress(session, progress) do
    transition(session, :crf_searching, %{
      active_video_id: Map.get(progress, :video_id, session.active_video_id),
      transfer_progress: nil,
      crf_search_progress: progress
    })
  end
end
