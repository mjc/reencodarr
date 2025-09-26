defmodule Reencodarr.PipelineStateMachine do
  @moduledoc "State machine for Broadway pipeline management with integrated event broadcasting"

  require Logger
  alias Reencodarr.Dashboard.Events

  @type service :: :analyzer | :crf_searcher | :encoder
  @type state :: :stopped | :idle | :running | :processing | :pausing | :paused

  @states [:stopped, :idle, :running, :processing, :pausing, :paused]
  @services [:analyzer, :crf_searcher, :encoder]

  # Valid state transitions
  @transitions_from_stopped [:idle, :running, :paused]
  @transitions_from_idle [:running, :processing, :paused, :stopped]
  @transitions_from_running [:processing, :idle, :pausing, :paused, :stopped]
  @transitions_from_processing [:idle, :running, :pausing, :stopped]
  @transitions_from_pausing [:paused, :stopped]
  @transitions_from_paused [:idle, :running, :stopped]

  @type t :: %__MODULE__{service: service, current_state: state}
  defstruct [:service, :current_state]

  # Factory function
  def new(service) when service in @services do
    pipeline = %__MODULE__{service: service, current_state: :paused}
    Events.pipeline_state_changed(service, :stopped, :paused)
    pipeline
  end

  # Get current state
  def get_state(%__MODULE__{current_state: state}), do: state

  # Valid state transitions with pattern matching
  def transition_to(%{service: s, current_state: :stopped} = m, new_s)
      when new_s in @transitions_from_stopped do
    Events.pipeline_state_changed(s, :stopped, new_s)
    %{m | current_state: new_s}
  end

  def transition_to(%{service: s, current_state: :idle} = m, new_s)
      when new_s in @transitions_from_idle do
    Events.pipeline_state_changed(s, :idle, new_s)
    %{m | current_state: new_s}
  end

  def transition_to(%{service: s, current_state: :running} = m, new_s)
      when new_s in @transitions_from_running do
    Events.pipeline_state_changed(s, :running, new_s)
    %{m | current_state: new_s}
  end

  def transition_to(%{service: s, current_state: :processing} = m, new_s)
      when new_s in @transitions_from_processing do
    Events.pipeline_state_changed(s, :processing, new_s)
    %{m | current_state: new_s}
  end

  def transition_to(%{service: s, current_state: :pausing} = m, new_s)
      when new_s in @transitions_from_pausing do
    Events.pipeline_state_changed(s, :pausing, new_s)
    %{m | current_state: new_s}
  end

  def transition_to(%{service: s, current_state: :paused} = m, new_s)
      when new_s in @transitions_from_paused do
    Events.pipeline_state_changed(s, :paused, new_s)
    %{m | current_state: new_s}
  end

  # Invalid transitions - catch-all
  def transition_to(%{service: s, current_state: c} = m, new_s) do
    Logger.warning("Invalid state transition for #{s} from #{c} to #{new_s}")
    m
  end

  # High-level operations
  def pause(%{current_state: :processing} = m), do: transition_to(m, :pausing)
  def pause(m), do: transition_to(m, :paused)

  def resume(%{current_state: c} = m) when c in [:paused, :stopped],
    do: transition_to(m, :running)

  def resume(m), do: m
  def work_available(%{current_state: :idle} = m), do: transition_to(m, :running)
  def work_available(m), do: m

  def start_processing(%{current_state: c} = m) when c in [:idle, :running],
    do: transition_to(m, :processing)

  def start_processing(m), do: m

  def work_completed(%{current_state: :processing} = m, more?),
    do: transition_to(m, if(more?, do: :running, else: :idle))

  def work_completed(%{current_state: :pausing} = m, _), do: transition_to(m, :paused)
  def work_completed(m, _), do: m

  # State query functions - handle both atoms and structs
  def available_for_work?(s) when is_atom(s) and s in @states, do: s in [:idle, :running]
  def available_for_work?(%{current_state: state}), do: available_for_work?(state)
  def available_for_work?(_), do: false

  def actively_working?(s) when is_atom(s) and s in @states, do: s == :processing
  def actively_working?(%{current_state: state}), do: actively_working?(state)
  def actively_working?(_), do: false

  def running?(s) when is_atom(s) and s in @states,
    do: s in [:idle, :running, :processing, :pausing]

  def running?(%{current_state: state}), do: running?(state)

  def running?(s) when is_atom(s),
    do: raise(FunctionClauseError, "no function clause matching in running?/1 for #{inspect(s)}")

  def running?(_), do: false
end
