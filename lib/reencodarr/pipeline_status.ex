defmodule Reencodarr.PipelineStatus do
  @moduledoc """
  Shared pipeline status logic for all Broadway producers (Analyzer, CrfSearcher, Encoder).

  This centralizes the complex status determination logic that was duplicated across
  all three services, making it easier to maintain and ensuring consistent behavior.
  """

  alias GenStage
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Media

  @type service :: :analyzer | :crf_searcher | :encoder
  @type broadway_module ::
          Reencodarr.Analyzer.Broadway
          | Reencodarr.CrfSearcher.Broadway
          | Reencodarr.Encoder.Broadway

  @doc """
  Request a service to broadcast its current status.
  Uses async cast to avoid blocking.
  """
  @spec broadcast_current_status(service()) :: :ok
  def broadcast_current_status(service) do
    producer_module = get_producer_module(service)

    case Process.whereis(producer_module) do
      nil ->
        broadcast_service_event(service, :stopped)

      _pid ->
        GenServer.cast(producer_module, :broadcast_status)
    end

    :ok
  end

  @doc """
  Get the current status of a service without broadcasting.
  Since we can't reliably query status without blocking, return unknown.
  Services should broadcast their actual status via PubSub.
  """
  @spec get_service_status(service()) :: :stopped | :unknown
  def get_service_status(service) do
    case Process.whereis(get_broadway_module(service)) do
      nil -> :stopped
      # Let the process broadcast its actual status
      _pid -> :unknown
    end
  end

  @doc """
  Handle pause cast for a Broadway producer with consistent status management.
  Returns the new GenStage response.
  """
  @spec handle_pause_cast(service(), map()) :: {:noreply, [], map()}
  def handle_pause_cast(service, state) do
    case state.status do
      :processing ->
        broadcast_service_event(service, :pausing)

        {:noreply, [], %{state | status: :pausing}}

        broadcast_service_event(service, :idle)

        {:noreply, [], %{state | status: :paused}}
    end
  end

  @doc """
  Handle resume cast for a Broadway producer with consistent status management.
  Returns the new GenStage response.
  """
  @spec handle_resume_cast(service(), map(), function()) :: {:noreply, [], map()}
  def handle_resume_cast(service, state, dispatch_func) do
    broadcast_service_event(service, :started)

    new_state = %{state | status: :running}
    dispatch_func.(new_state)
  end

  @doc """
  Handle dispatch_available cast for a Broadway producer with pausing logic.
  Returns the new GenStage response.
  """
  @spec handle_dispatch_available_cast(service(), map(), function()) :: {:noreply, [], map()}
  def handle_dispatch_available_cast(service, state, dispatch_func) do
    case state.status do
      :pausing ->
        broadcast_service_event(service, :idle)

        new_state = %{state | status: :paused}
        {:noreply, [], new_state}

      _ ->
        new_state = %{state | status: :running}
        dispatch_func.(new_state)
    end
  end

  # DRY helper for broadcasting service events
  defp broadcast_service_event(service, event_type) do
    Events.broadcast_event(:"#{service}_#{event_type}")
  end

  @services [:analyzer, :crf_searcher, :encoder]

  @doc """
  Get queue counts for all services.
  """
  @spec get_all_queue_counts() :: %{
          analyzer: non_neg_integer(),
          crf_searcher: non_neg_integer(),
          encoder: non_neg_integer()
        }
  def get_all_queue_counts do
    map_all_services(&get_queue_count/1)
  end

  @doc """
  Get queue count for a specific service.
  """
  @spec get_queue_count(service()) :: non_neg_integer()
  def get_queue_count(service) do
    count_work_available(service)
  end

  @doc """
  Get service status for all services.
  """
  @spec get_all_service_status() :: %{analyzer: atom(), crf_searcher: atom(), encoder: atom()}
  def get_all_service_status do
    map_all_services(&get_service_status/1)
  end

  # Private functions

  # Private functions

  # Helper to apply a function to all services and return a map
  defp map_all_services(func) do
    @services
    |> Enum.map(&{&1, func.(&1)})
    |> Map.new()
  end

  @doc """
  Send a message to a service's Broadway producer.
  Returns :ok on success or {:error, reason} on failure.
  """
  @spec send_to_producer(service(), term()) :: :ok | {:error, term()}
  def send_to_producer(service, message) do
    case find_producer_process(service) do
      nil -> {:error, :producer_not_found}
      producer_pid -> GenStage.cast(producer_pid, message)
    end
  end

  @doc """
  Find the actual producer process for a service.
  """
  @spec find_producer_process(service()) :: pid() | nil
  def find_producer_process(service) do
    broadway_name = get_broadway_name(service)
    producer_supervisor_name = :"#{broadway_name}.Broadway.ProducerSupervisor"

    with pid when is_pid(pid) <- Process.whereis(producer_supervisor_name),
         children <- Supervisor.which_children(pid),
         producer_pid when is_pid(producer_pid) <- find_actual_producer(children) do
      producer_pid
    else
      _ -> nil
    end
  end

  defp find_actual_producer(children) do
    Enum.find_value(children, fn {_id, pid, _type, _modules} ->
      if is_pid(pid) do
        try do
          GenStage.call(pid, :running?, 1000)
          pid
        catch
          :exit, _ -> nil
        end
      end
    end)
  end

  defp get_broadway_name(:analyzer), do: "Reencodarr.Analyzer"
  defp get_broadway_name(:crf_searcher), do: "Reencodarr.CrfSearcher"
  defp get_broadway_name(:encoder), do: "Reencodarr.Encoder"

  defp get_producer_module(service) do
    service
    |> get_broadway_module()
    |> Module.concat(Producer)
  end

  defp get_broadway_module(:analyzer), do: Reencodarr.Analyzer.Broadway
  defp get_broadway_module(:crf_searcher), do: Reencodarr.CrfSearcher.Broadway
  defp get_broadway_module(:encoder), do: Reencodarr.Encoder.Broadway

  defp count_work_available(:analyzer) do
    Media.count_videos_needing_analysis()
  rescue
    _ -> 0
  end

  defp count_work_available(:crf_searcher) do
    Media.count_videos_for_crf_search()
  rescue
    _ -> 0
  end

  defp count_work_available(:encoder) do
    Media.encoding_queue_count()
  rescue
    _ -> 0
  end
end
