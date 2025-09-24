defmodule Reencodarr.PipelineStateMachine do
  @moduledoc """
  State machine for Broadway pipeline statuses across all three services.

  This module provides a struct that each producer maintains to track their state
  and handle transitions with integrated broadcasting.

  ## States:
  - :stopped - Pipeline is not running (initial state or after failure)
  - :idle - Pipeline is running but not actively processing (waiting for work)
  - :running - Pipeline is running and ready to accept work
  - :processing - Pipeline is actively processing items
  - :pausing - Pipeline is transitioning from processing/running to paused
  - :paused - Pipeline is paused by user (can be resumed)

  All three pipelines (analyzer, crf_searcher, encoder) use these same states.

  ## Integrated Broadcasting
  The state machine handles all event broadcasting automatically:
  - Dashboard events via Events.broadcast_event()
  - PubSub notifications via Phoenix.PubSub.broadcast()
  - Telemetry events via both Telemetry.emit_*() and :telemetry.execute()
  """

  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Telemetry

  @type pipeline_state :: :stopped | :idle | :running | :processing | :pausing | :paused
  @type service :: :analyzer | :crf_searcher | :encoder

  # All valid pipeline states
  @valid_states [:stopped, :idle, :running, :processing, :pausing, :paused]

  # Valid state transitions - defines what state changes are allowed
  @valid_transitions %{
    # From stopped state
    stopped: [:idle, :running, :paused],

    # From idle state (waiting for work)
    idle: [:running, :processing, :paused, :stopped],

    # From running state (ready to process)
    running: [:processing, :idle, :pausing, :paused, :stopped],

    # From processing state (actively working)
    processing: [:idle, :running, :pausing, :stopped],

    # From pausing state (transitioning to paused)
    pausing: [:paused, :stopped],

    # From paused state (user paused)
    paused: [:running, :idle, :stopped]
  }

  @doc """
  Struct to represent a pipeline state machine instance.
  Each producer should maintain one of these in their state.
  """
  defstruct [:service, :current_state]

  @type t :: %__MODULE__{
          service: service(),
          current_state: pipeline_state()
        }

  # =============================================================================
  # STRUCT API FUNCTIONS
  # =============================================================================

  @doc """
  Creates a new pipeline state machine instance.
  """
  @spec new(service()) :: t()
  def new(service) when service in [:analyzer, :crf_searcher, :encoder] do
    state_machine = %__MODULE__{
      service: service,
      current_state: initial_state()
    }

    # Broadcast initial state
    broadcast_state_transition(service, :stopped, initial_state())

    state_machine
  end

  @doc """
  Get the current state of a pipeline state machine.
  """
  @spec get_state(t()) :: pipeline_state()
  def get_state(%__MODULE__{current_state: state}), do: state

  @doc """
  Transition to a new state with automatic broadcasting.
  """
  @spec transition_to(t(), pipeline_state()) :: t()
  def transition_to(
        %__MODULE__{service: service, current_state: current_state} = state_machine,
        new_state
      ) do
    case transition(current_state, new_state) do
      {:ok, validated_state} ->
        broadcast_state_transition(service, current_state, validated_state)
        %{state_machine | current_state: validated_state}

      {:error, reason} ->
        require Logger

        Logger.warning(
          "Invalid state transition for #{service} from #{current_state} to #{new_state}: #{reason}"
        )

        state_machine
    end
  end

  # =============================================================================
  # HIGH-LEVEL OPERATIONS
  # =============================================================================

  @doc """
  Handle pause request with proper state transitions.
  """
  @spec pause(t()) :: t()
  def pause(%__MODULE__{current_state: current_state} = state_machine) do
    new_state =
      case current_state do
        # Need to finish current work
        :processing -> :pausing
        # Can pause immediately
        state when state in [:idle, :running] -> :paused
        # Allow pausing from stopped
        :stopped -> :paused
        # Already paused
        :paused -> :paused
        # Already pausing
        :pausing -> :pausing
      end

    transition_to(state_machine, new_state)
  end

  @doc """
  Handle resume request with proper state transitions.
  """
  @spec resume(t()) :: t()
  def resume(%__MODULE__{current_state: current_state} = state_machine) do
    new_state =
      case current_state do
        state when state in [:paused, :stopped] -> :running
        # Already running in some form
        state -> state
      end

    transition_to(state_machine, new_state)
  end

  @doc """
  Handle work completion with proper state transitions.
  """
  @spec work_completed(t(), boolean()) :: t()
  def work_completed(
        %__MODULE__{current_state: current_state} = state_machine,
        more_work_available?
      ) do
    new_state =
      case current_state do
        :processing when more_work_available? -> :running
        :processing -> :idle
        # Finish pausing process
        :pausing -> :paused
        # No change needed for other states
        state -> state
      end

    transition_to(state_machine, new_state)
  end

  @doc """
  Handle when work becomes available.
  """
  @spec work_available(t()) :: t()
  def work_available(%__MODULE__{current_state: :idle} = state_machine) do
    transition_to(state_machine, :running)
  end

  # No change for other states
  def work_available(state_machine), do: state_machine

  @doc """
  Start processing work.
  """
  @spec start_processing(t()) :: t()
  def start_processing(%__MODULE__{current_state: current_state} = state_machine)
      when current_state in [:running, :idle] do
    transition_to(state_machine, :processing)
  end

  # No change if not ready
  def start_processing(state_machine), do: state_machine

  # =============================================================================
  # STATE QUERIES
  # =============================================================================

  @doc """
  Check if the pipeline is running (any active state).
  Accepts either a PipelineStateMachine struct or a state atom.
  """
  @spec running?(t() | pipeline_state()) :: boolean()
  def running?(%__MODULE__{current_state: state}), do: running?(state)

  def running?(state) when state in @valid_states do
    state in [:idle, :running, :processing, :pausing]
  end

  @doc """
  Check if the pipeline is actively working.
  Accepts either a PipelineStateMachine struct or a state atom.
  """
  @spec actively_working?(t() | pipeline_state()) :: boolean()
  def actively_working?(%__MODULE__{current_state: state}), do: actively_working?(state)

  def actively_working?(state) when state in @valid_states do
    state in [:processing]
  end

  @doc """
  Check if the pipeline is available for work.
  Accepts either a PipelineStateMachine struct or a state atom.
  """
  @spec available_for_work?(t() | pipeline_state()) :: boolean()
  def available_for_work?(%__MODULE__{current_state: state}), do: available_for_work?(state)

  def available_for_work?(state) when state in @valid_states do
    state in [:idle, :running]
  end

  # =============================================================================
  # PRODUCER INTEGRATION HELPERS
  # =============================================================================

  @doc """
  Helper for producers to handle pause casts with state machine integration.
  Returns {:noreply, [], updated_state} tuple suitable for GenStage.
  """
  def handle_pause_cast(producer_state, pipeline_field_name \\ :pipeline) do
    pipeline = Map.get(producer_state, pipeline_field_name)
    updated_pipeline = pause(pipeline)
    updated_state = Map.put(producer_state, pipeline_field_name, updated_pipeline)
    {:noreply, [], updated_state}
  end

  @doc """
  Helper for producers to handle resume casts with state machine integration.
  Returns {:noreply, [], updated_state} tuple and runs dispatch function.
  """
  def handle_resume_cast(producer_state, dispatch_func, pipeline_field_name \\ :pipeline) do
    pipeline = Map.get(producer_state, pipeline_field_name)
    updated_pipeline = resume(pipeline)
    updated_state = Map.put(producer_state, pipeline_field_name, updated_pipeline)

    # Run dispatch function if now available for work
    if available_for_work?(updated_pipeline) do
      dispatch_func.(updated_state)
    else
      {:noreply, [], updated_state}
    end
  end

  @doc """
  Helper for producers to handle work completion with state machine integration.
  """
  def handle_work_completion_cast(
        producer_state,
        more_work?,
        dispatch_func,
        pipeline_field_name \\ :pipeline
      ) do
    pipeline = Map.get(producer_state, pipeline_field_name)
    updated_pipeline = work_completed(pipeline, more_work?)
    updated_state = Map.put(producer_state, pipeline_field_name, updated_pipeline)

    # Continue dispatching if more work is available and we're ready
    if more_work? and available_for_work?(updated_pipeline) do
      dispatch_func.(updated_state)
    else
      {:noreply, [], updated_state}
    end
  end

  @doc """
  Helper for producers to handle dispatch available casts.
  """
  def handle_dispatch_available_cast(
        producer_state,
        dispatch_func,
        pipeline_field_name \\ :pipeline
      ) do
    pipeline = Map.get(producer_state, pipeline_field_name)

    case get_state(pipeline) do
      :pausing ->
        # Job finished while pausing - now fully paused
        updated_pipeline = transition_to(pipeline, :paused)
        updated_state = Map.put(producer_state, pipeline_field_name, updated_pipeline)
        {:noreply, [], updated_state}

      _ ->
        # Continue with work if available
        updated_pipeline = work_available(pipeline)
        updated_state = Map.put(producer_state, pipeline_field_name, updated_pipeline)
        dispatch_func.(updated_state)
    end
  end

  @doc """
  Helper for producers to broadcast their current status.
  """
  def handle_broadcast_status_cast(producer_state, pipeline_field_name \\ :pipeline) do
    pipeline = Map.get(producer_state, pipeline_field_name)
    current_state = get_state(pipeline)

    # Re-broadcast current state (this will trigger all the events)
    service = pipeline.service
    broadcast_state_transition(service, current_state, current_state)

    {:noreply, [], producer_state}
  end

  @doc """
  Helper for producers to start processing work.
  """
  def handle_start_processing(producer_state, pipeline_field_name \\ :pipeline) do
    pipeline = Map.get(producer_state, pipeline_field_name)
    updated_pipeline = start_processing(pipeline)
    Map.put(producer_state, pipeline_field_name, updated_pipeline)
  end

  # =============================================================================
  # LEGACY PRODUCER FUNCTIONS (old status-based API)
  # =============================================================================

  @doc """
  Legacy function for producers with :status field instead of :pipeline field.
  """
  def handle_producer_pause_cast(service, producer_state) do
    current_status = Map.get(producer_state, :status, :idle)

    case transition_with_broadcast(service, current_status, :paused) do
      {:ok, new_status} ->
        new_state = Map.put(producer_state, :status, new_status)
        {:noreply, [], new_state}

      {:error, _reason} ->
        {:noreply, [], producer_state}
    end
  end

  @doc """
  Legacy function for producers with :status field instead of :pipeline field.
  """
  def handle_producer_resume_cast(service, producer_state, dispatch_func) do
    current_status = Map.get(producer_state, :status, :idle)

    case transition_with_broadcast(service, current_status, :running) do
      {:ok, new_status} ->
        new_state = Map.put(producer_state, :status, new_status)
        dispatch_func.(new_state)

      {:error, _reason} ->
        {:noreply, [], producer_state}
    end
  end

  @doc """
  Legacy function for producers with :status field instead of :pipeline field.
  """
  def handle_producer_broadcast_status_cast(service, producer_state) do
    current_status = Map.get(producer_state, :status, :idle)
    # Re-broadcast current state
    broadcast_state_transition(service, current_status, current_status)
    {:noreply, [], producer_state}
  end

  # =============================================================================
  # VALIDATION AND TRANSITION LOGIC
  # =============================================================================

  @doc """
  Returns all valid pipeline states.
  """
  def valid_states, do: @valid_states

  @doc """
  Get valid transitions from a given state.
  """
  def valid_transitions(from_state) when from_state in @valid_states do
    @valid_transitions[from_state] || []
  end

  def valid_transitions(_invalid_state), do: []

  @doc """
  Check if a state transition is valid.
  """
  def valid_transition?(from_state, to_state)
      when from_state in @valid_states and to_state in @valid_states do
    to_state in (@valid_transitions[from_state] || [])
  end

  def valid_transition?(_, _), do: false

  @doc """
  Perform a state transition with validation.
  Returns {:ok, new_state} or {:error, reason}.
  """
  def transition(from_state, to_state) do
    if valid_transition?(from_state, to_state) do
      {:ok, to_state}
    else
      {:error, "Invalid transition from #{from_state} to #{to_state}"}
    end
  end

  @doc """
  Get the initial state for a pipeline.
  """
  def initial_state, do: :paused

  # =============================================================================
  # STATE TRANSITION FUNCTIONS WITH BROADCASTING
  # =============================================================================

  @doc """
  Perform a state transition with automatic broadcasting.
  Returns {:ok, new_state} or {:error, reason}.
  """
  @spec transition_with_broadcast(service(), pipeline_state(), pipeline_state()) ::
          {:ok, pipeline_state()} | {:error, String.t()}
  def transition_with_broadcast(service, from_state, to_state) do
    case transition(from_state, to_state) do
      {:ok, new_state} ->
        broadcast_state_transition(service, from_state, new_state)
        {:ok, new_state}

      error ->
        error
    end
  end

  @doc """
  Handle pause request with broadcasting.
  """
  @spec handle_pause_with_broadcast(service(), pipeline_state()) ::
          {:ok, pipeline_state()} | {:error, String.t()}
  def handle_pause_with_broadcast(service, current_state) do
    transition_with_broadcast(service, current_state, :paused)
  end

  @doc """
  Handle resume request with broadcasting.
  """
  @spec handle_resume_with_broadcast(service(), pipeline_state()) ::
          {:ok, pipeline_state()} | {:error, String.t()}
  def handle_resume_with_broadcast(service, current_state) do
    transition_with_broadcast(service, current_state, :running)
  end

  # =============================================================================
  # INTEGRATED BROADCASTING FUNCTIONS
  # =============================================================================

  @doc """
  Broadcasts all events for a state transition.
  """
  @spec broadcast_state_transition(service(), pipeline_state(), pipeline_state()) :: :ok
  def broadcast_state_transition(service, from_state, to_state)
      when service in [:analyzer, :crf_searcher, :encoder] do
    # Broadcast dashboard event
    event_name = state_to_event(service, to_state)
    Events.broadcast_event(event_name, %{})

    # Broadcast PubSub notification (for internal communication)
    pubsub_event = state_to_pubsub_event(service, to_state)
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, Atom.to_string(service), pubsub_event)

    # Emit telemetry events
    emit_telemetry_for_transition(service, from_state, to_state)

    :ok
  end

  # =============================================================================
  # PRIVATE FUNCTIONS
  # =============================================================================

  @doc """
  Maps pipeline states to dashboard event names.
  Public function for testing and external use.
  """
  @spec state_to_event(service(), pipeline_state()) :: atom()
  def state_to_event(:analyzer, state), do: analyzer_state_to_event(state)
  def state_to_event(:crf_searcher, state), do: crf_searcher_state_to_event(state)
  def state_to_event(:encoder, state), do: encoder_state_to_event(state)

  defp analyzer_state_to_event(:stopped), do: :analyzer_stopped
  defp analyzer_state_to_event(:idle), do: :analyzer_idle
  defp analyzer_state_to_event(:running), do: :analyzer_started
  defp analyzer_state_to_event(:processing), do: :analyzer_started
  defp analyzer_state_to_event(:pausing), do: :analyzer_pausing
  defp analyzer_state_to_event(:paused), do: :analyzer_paused

  defp crf_searcher_state_to_event(:stopped), do: :crf_searcher_stopped
  defp crf_searcher_state_to_event(:idle), do: :crf_searcher_idle
  defp crf_searcher_state_to_event(:running), do: :crf_searcher_started
  defp crf_searcher_state_to_event(:processing), do: :crf_searcher_started
  defp crf_searcher_state_to_event(:pausing), do: :crf_searcher_pausing
  defp crf_searcher_state_to_event(:paused), do: :crf_searcher_paused

  defp encoder_state_to_event(:stopped), do: :encoder_stopped
  defp encoder_state_to_event(:idle), do: :encoder_idle
  defp encoder_state_to_event(:running), do: :encoder_started
  defp encoder_state_to_event(:processing), do: :encoder_started
  defp encoder_state_to_event(:pausing), do: :encoder_pausing
  defp encoder_state_to_event(:paused), do: :encoder_paused

  # Maps pipeline states to PubSub event tuples
  defp state_to_pubsub_event(service, state) do
    action =
      case state do
        :stopped -> :stopped
        :idle -> :idle
        :running -> :started
        # Processing is still "started" for PubSub
        :processing -> :started
        :pausing -> :pausing
        :paused -> :paused
      end

    {service, action}
  end

  # Emits appropriate telemetry events for state transitions
  defp emit_telemetry_for_transition(service, from_state, to_state) do
    # Emit service-specific telemetry events
    case {service, to_state} do
      {:analyzer, :running} ->
        Telemetry.emit_analyzer_started()
        :telemetry.execute([:reencodarr, :analyzer, :started], %{}, %{})

      {:analyzer, :paused} ->
        Telemetry.emit_analyzer_paused()
        :telemetry.execute([:reencodarr, :analyzer, :paused], %{}, %{})

      {:crf_searcher, :paused} ->
        Telemetry.emit_crf_search_paused()

      {:encoder, :paused} ->
        Telemetry.emit_encoder_paused()

      _ ->
        # Generic telemetry event for all other transitions
        :telemetry.execute(
          [:reencodarr, service, :state_changed],
          %{},
          %{from_state: from_state, to_state: to_state}
        )
    end
  end
end
