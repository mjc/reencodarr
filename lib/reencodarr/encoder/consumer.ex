defmodule Reencodarr.Encoder.Consumer do
  @moduledoc """
  GenStage consumer for processing encoding operations.
  
  This consumer subscribes to the Encoder.Producer and processes videos
  by initiating encoding. It tracks ongoing operations and handles
  completion notifications via PubSub.
  """
  
  use GenStage
  require Logger
  alias Reencodarr.AbAv1

  def start_link do
    GenStage.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    # Subscribe to encoding completion events
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "encoding_events")

    {:consumer, %{pending_operations: %{}},
     subscribe_to: [{Reencodarr.Encoder.Producer, max_demand: 1}]}
  end

  @impl true
  def handle_events(vmafs, _from, state) do
    new_state =
      vmafs
      |> Enum.reduce(state, &process_vmaf_with_tracking/2)

    {:noreply, [], new_state}
  end

  # Handle encoding completion messages from PubSub
  @impl true
  def handle_info({:encoding_completed, vmaf_id, result}, state) do
    # Check if this operation was tracked by this consumer
    case Map.pop(state.pending_operations, vmaf_id) do
      {nil, _pending_operations} ->
        # Operation not tracked by this consumer, ignore
        {:noreply, [], state}

      {vmaf, new_pending} ->
        # Remove from pending operations
        new_state = %{state | pending_operations: new_pending}

        case result do
          :success ->
            Logger.info("Completed encoding for #{vmaf.video.path}")

          :skipped ->
            Logger.info("Skipped encoding for #{vmaf.video.path} (already in progress)")

          {:error, exit_code} ->
            Logger.error("Encoding failed for #{vmaf.video.path} with exit code: #{exit_code}")
        end

        {:noreply, [], new_state}
    end
  end

  defp process_vmaf_with_tracking(vmaf, state) do
    operation_id = vmaf.id

    # Check if this vmaf is already being processed
    case Map.has_key?(state.pending_operations, operation_id) do
      false ->
        Logger.info("Starting encoding for #{vmaf.video.path}")

        # Start encoding
        AbAv1.encode(vmaf)

        # Track the operation
        new_pending = Map.put(state.pending_operations, operation_id, vmaf)
        %{state | pending_operations: new_pending}

      true ->
        Logger.debug("Encoding already in progress for #{vmaf.video.path}, skipping")
        state
    end
  end
end
