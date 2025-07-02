defmodule Reencodarr.GenStage.BaseConsumer do
  @moduledoc """
  Base behaviour for GenStage consumers in the Reencodarr pipeline.

  This module provides a common pattern for consumers that:
  - Subscribe to PubSub completion events
  - Use manual demand mode to prevent duplicate operations
  - Process items one at a time
  - Handle completion events properly
  """

  @doc """
  Process a single item from the producer.
  """
  @callback process_item(item :: any()) :: :ok

  @doc """
  Get the PubSub topic for completion events.
  """
  @callback completion_event_topic() :: String.t()

  @doc """
  Extract the ID from an item for tracking.
  """
  @callback item_id(item :: any()) :: any()

  @doc """
  Get the producer module for this consumer.
  """
  @callback producer_module() :: module()

  @doc """
  Log the start of processing.
  """
  @callback log_start(item :: any()) :: :ok

  @doc """
  Log the completion of processing.
  """
  @callback log_completion(item_id :: any(), result :: any()) :: :ok

  defmacro __using__(_opts) do
    quote do
      use GenStage
      require Logger

      @behaviour Reencodarr.GenStage.BaseConsumer

      def start_link(opts \\ []) do
        GenStage.start_link(__MODULE__, :ok, opts)
      end

      @impl true
      def init(:ok) do
        # Subscribe to completion events
        Phoenix.PubSub.subscribe(Reencodarr.PubSub, completion_event_topic())

        # Start with manual demand
        {:consumer, %{current_item_id: nil, producer_from: nil},
         subscribe_to: [{producer_module(), min_demand: 0, max_demand: 1}]}
      end

      @impl true
      def handle_subscribe(:producer, _opts, from, state) do
        # Ask for first item and store producer reference
        GenStage.ask(from, 1)
        {:manual, %{state | producer_from: from}}
      end

      @impl true
      def handle_events([item], _from, state) do
        log_start(item)

        # Process the item and track its ID
        process_item(item)
        new_state = %{state | current_item_id: item_id(item)}

        {:noreply, [], new_state}
      end

      # Handle CRF search completion events
      @impl true
      def handle_info(
            {:crf_search_completed, item_id, result},
            %{current_item_id: current_item_id} = state
          )
          when item_id == current_item_id do
        log_completion(item_id, result)

        # Clear current item and ask for next one
        new_state = %{state | current_item_id: nil}
        GenStage.ask(state.producer_from, 1)
        {:noreply, [], new_state}
      end

      # Handle encoding completion events
      @impl true
      def handle_info(
            {:encoding_completed, item_id, result},
            %{current_item_id: current_item_id} = state
          )
          when item_id == current_item_id do
        log_completion(item_id, result)

        # Clear current item and ask for next one
        new_state = %{state | current_item_id: nil}
        GenStage.ask(state.producer_from, 1)
        {:noreply, [], new_state}
      end

      # Ignore completion events for other items
      def handle_info({:crf_search_completed, _other_item_id, _result}, state) do
        {:noreply, [], state}
      end

      def handle_info({:encoding_completed, _other_item_id, _result}, state) do
        {:noreply, [], state}
      end

      # Allow overriding in implementing modules
      defoverridable start_link: 0, start_link: 1
    end
  end
end
