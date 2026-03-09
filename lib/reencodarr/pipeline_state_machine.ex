defmodule Reencodarr.PipelineStateMachine do
  @moduledoc "State machine for Broadway pipeline management with integrated event broadcasting"

  require Logger
  alias Reencodarr.Dashboard.Events

  @type service :: :analyzer | :crf_searcher | :encoder
  @type state :: :stopped | :idle | :running | :processing | :pausing | :paused

  @states [:stopped, :idle, :running, :processing, :pausing, :paused]
  @services [:analyzer, :crf_searcher, :encoder]

  @valid_transitions %{
    stopped: [:idle, :running, :paused],
    idle: [:running, :processing, :paused, :stopped],
    running: [:processing, :idle, :pausing, :paused, :stopped],
    processing: [:idle, :running, :pausing, :stopped],
    pausing: [:paused, :stopped],
    paused: [:idle, :running, :stopped]
  }

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

  def transition_to(%{service: service, current_state: current} = machine, new_state) do
    if new_state in Map.get(@valid_transitions, current, []) do
      Events.pipeline_state_changed(service, current, new_state)
      %{machine | current_state: new_state}
    else
      Logger.warning("Invalid state transition for #{service} from #{current} to #{new_state}")
      machine
    end
  end

  # High-level operations
  def pause(%{current_state: :processing} = m), do: transition_to(m, :pausing)
  def pause(m), do: transition_to(m, :paused)

  @doc """
  Handle pause request with proper state checking to avoid duplicate transitions.
  Returns the updated pipeline state machine.
  """
  def handle_pause_request(%{current_state: :processing} = m), do: pause(m)
  def handle_pause_request(%{current_state: :pausing} = m), do: m
  def handle_pause_request(m), do: transition_to(m, :paused)

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
    do:
      raise(ArgumentError, message: "no function clause matching in running?/1 for #{inspect(s)}")

  def running?(_), do: false
end
