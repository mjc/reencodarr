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

    # Start with no demand - we'll ask for the first VMAF manually
    {:consumer, %{current_vmaf_id: nil},
     subscribe_to: [{Reencodarr.Encoder.Producer, min_demand: 0, max_demand: 1}]}
  end

  @impl true
  def handle_subscribe(:producer, _opts, from, state) do
    # When we first subscribe to the producer, ask for 1 VMAF
    GenStage.ask(from, 1)
    {:manual, state}
  end

  @impl true
  def handle_events([vmaf], _from, state) do
    Logger.info("Starting encoding for #{vmaf.video.path}")

    # Start encoding and track the current VMAF ID
    AbAv1.encode(vmaf)
    new_state = %{state | current_vmaf_id: vmaf.id}

    {:noreply, [], new_state}
  end

  # Handle encoding completion messages from PubSub
  @impl true
  def handle_info({:encoding_completed, vmaf_id, result}, %{current_vmaf_id: current_vmaf_id} = state)
      when vmaf_id == current_vmaf_id do
    # Log the completion
    case result do
      :success -> Logger.info("Completed encoding for VMAF #{vmaf_id}")
      :skipped -> Logger.info("Skipped encoding for VMAF #{vmaf_id} (already in progress)")
      {:error, exit_code} -> Logger.error("Encoding failed for VMAF #{vmaf_id} with exit code: #{exit_code}")
    end

    # Clear current VMAF and ask for the next one
    new_state = %{state | current_vmaf_id: nil}
    GenStage.ask(Reencodarr.Encoder.Producer, 1)
    {:noreply, [], new_state}
  end

  # Ignore completion events for other VMAFs
  def handle_info({:encoding_completed, _other_vmaf_id, _result}, state) do
    {:noreply, [], state}
  end

end
