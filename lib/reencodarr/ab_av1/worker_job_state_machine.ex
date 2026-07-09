defmodule Reencodarr.AbAv1.WorkerJobStateMachine do
  @moduledoc """
  State machine for one connected worker's current job phase.
  """

  require Logger

  @type phase :: :idle | :receiving_input | :input_ready | :crf_searching

  @valid_phases [:idle, :receiving_input, :input_ready, :crf_searching]

  @valid_transitions %{
    idle: [:receiving_input, :crf_searching],
    receiving_input: [:receiving_input, :input_ready, :crf_searching, :idle],
    input_ready: [:receiving_input, :crf_searching, :idle],
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
    with :ok <- ensure_same_active_video(session, video_id) do
      transition(session, phase, %{
        active_video_id: video_id,
        transfer_progress: nil,
        crf_search_progress: nil
      })
    end
  end

  @spec clear_video(map()) :: {:ok, map()}
  def clear_video(session) do
    {:ok,
     %{session | active_video_id: nil, transfer_progress: nil, crf_search_progress: nil}
     |> Map.put(:phase, :idle)}
  end

  @spec set_transfer_progress(map(), map()) :: {:ok, map()} | {:error, :invalid_worker_phase}
  def set_transfer_progress(%{phase: phase} = session, progress)
      when phase in [:idle, :receiving_input, :input_ready] do
    with {:ok, video_id} <- progress_video_id(session, progress) do
      transition(session, :receiving_input, %{
        active_video_id: video_id,
        transfer_progress: progress,
        crf_search_progress: nil
      })
    end
  end

  def set_transfer_progress(_session, _progress), do: {:error, :invalid_worker_phase}

  @spec finish_transfer(map()) :: {:ok, map()} | {:error, :invalid_worker_phase}
  def finish_transfer(%{active_video_id: nil} = session), do: clear_video(session)

  def finish_transfer(session) do
    transition(session, :input_ready)
  end

  @spec set_crf_search_progress(map(), map()) :: {:ok, map()} | {:error, :invalid_worker_phase}
  def set_crf_search_progress(session, progress) do
    with {:ok, video_id} <- progress_video_id(session, progress) do
      transition(session, :crf_searching, %{
        active_video_id: video_id,
        transfer_progress: nil,
        crf_search_progress: progress
      })
    end
  end

  defp ensure_same_active_video(%{active_video_id: nil}, _video_id), do: :ok
  defp ensure_same_active_video(%{active_video_id: video_id}, video_id), do: :ok
  defp ensure_same_active_video(_session, _video_id), do: {:error, :invalid_worker_phase}

  defp progress_video_id(session, progress) do
    progress_video_id = Map.get(progress, :video_id)

    case {session.active_video_id, progress_video_id} do
      {video_id, video_id} when is_integer(video_id) -> {:ok, video_id}
      {nil, video_id} when is_integer(video_id) -> {:ok, video_id}
      {video_id, nil} when is_integer(video_id) -> {:ok, video_id}
      _ -> {:error, :invalid_worker_phase}
    end
  end
end
