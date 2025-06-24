defmodule Reencodarr.Distributed.JobWorker do
  @moduledoc """
  Shared behavior for job worker GenServers (CrfSearcher and Encoder).

  Provides common functionality for handling delegated jobs, including:
  - Capability checking
  - Auto-starting when jobs arrive
  - Job queueing when busy
  - Local processing with RPC fallback for database operations
  """

  defmacro __using__(opts) do
    capability = Keyword.fetch!(opts, :capability)
    job_processor = Keyword.fetch!(opts, :job_processor)
    runner_module = Keyword.fetch!(opts, :runner_module)
    pubsub_topic = Keyword.fetch!(opts, :pubsub_topic)
    running_state_key = Keyword.fetch!(opts, :running_state_key)
    delegate_message = Keyword.fetch!(opts, :delegate_message)

    # Convert string topic to atom for message payload
    pubsub_topic_atom = String.to_atom(pubsub_topic)

    quote do
      require Logger
      alias Reencodarr.Distributed.Coordinator

      @capability unquote(capability)
      @job_processor unquote(job_processor)
      @runner_module unquote(runner_module)
      @pubsub_topic unquote(pubsub_topic)
      @pubsub_topic_atom unquote(pubsub_topic_atom)
      @running_state_key unquote(running_state_key)
      @delegate_message unquote(delegate_message)

      @doc """
      Handle delegated job processing with shared logic.
      """
      def handle_cast({@delegate_message, job}, state) do
        video_id = extract_video_id(job)
        Logger.info("Received delegated #{@capability} for video: #{video_id}")

        # Check if we have the capability to process this job
        local_capabilities = Coordinator.get_local_capabilities()
        has_capability = @capability in local_capabilities

        if not has_capability do
          Logger.warning(
            "Cannot process delegated #{@capability} for video #{video_id} - node does not have #{@capability} capability"
          )

          {:noreply, state}
        else
          # Process the job locally - the runner module will handle database operations via RPC if needed
          runner_running = @runner_module.running?()
          current_running = Map.get(state, @running_state_key)

          Logger.debug(
            "#{__MODULE__} state - #{@running_state_key}: #{current_running}, #{@runner_module}.running?: #{runner_running}"
          )

          cond do
            not current_running ->
              Logger.info(
                "Auto-starting #{__MODULE__} to process delegated job for video #{video_id}"
              )

              # Auto-start and process the job
              Phoenix.PubSub.broadcast(
                Reencodarr.PubSub,
                @pubsub_topic,
                {@pubsub_topic_atom, :started}
              )

              schedule_check()

              if not runner_running do
                Logger.info("Processing delegated #{@capability} for video: #{video_id}")
                @job_processor.(job)
              end

              {:noreply, Map.put(state, @running_state_key, true)}

            runner_running ->
              Logger.info(
                "#{@capability} already running, queueing delegated job for video #{video_id}"
              )

              updated_queue = state.job_queue ++ [job]
              {:noreply, %{state | job_queue: updated_queue}}

            true ->
              Logger.info("Processing delegated #{@capability} for video: #{video_id}")
              @job_processor.(job)
              {:noreply, state}
          end
        end
      end

      # This function must be implemented by the using module
      defp extract_video_id(job)

      defoverridable extract_video_id: 1
    end
  end
end
