defmodule Reencodarr.PipelineStatus do
  @moduledoc """
  Shared pipeline status logic for all Broadway producers (Analyzer, CrfSearcher, Encoder).

  This centralizes the complex status determination logic that was duplicated across
  all three services, making it easier to maintain and ensuring consistent behavior.
  """

  alias Reencodarr.Dashboard.Events

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
      nil -> broadcast_stopped_status(service)
      _pid -> GenServer.cast(producer_module, :broadcast_status)
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
  Broadcast that a service has started.
  """
  @spec broadcast_started(service()) :: :ok
  def broadcast_started(:analyzer), do: Events.analyzer_started()
  def broadcast_started(:crf_searcher), do: Events.crf_searcher_started()
  def broadcast_started(:encoder), do: Events.encoder_started()

  @doc """
  Broadcast that a service is pausing.
  """
  @spec broadcast_pausing(service()) :: :ok
  def broadcast_pausing(:analyzer), do: Events.analyzer_pausing()
  def broadcast_pausing(:crf_searcher), do: Events.crf_searcher_pausing()
  def broadcast_pausing(:encoder), do: Events.encoder_pausing()

  @doc """
  Broadcast that a service has stopped.
  """
  @spec broadcast_stopped_status(service()) :: :ok
  def broadcast_stopped_status(:analyzer), do: Events.analyzer_stopped()
  def broadcast_stopped_status(:crf_searcher), do: Events.crf_searcher_stopped()
  def broadcast_stopped_status(:encoder), do: Events.encoder_stopped()

  @doc """
  Broadcast that a service is idle.
  """
  @spec broadcast_idle_status(service()) :: :ok
  def broadcast_idle_status(:analyzer), do: Events.analyzer_idle()
  def broadcast_idle_status(:crf_searcher), do: Events.crf_searcher_idle()
  def broadcast_idle_status(:encoder), do: Events.encoder_idle()

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
    for_all_services(&get_queue_count/1)
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
    for_all_services(&get_service_status/1)
  end

  # Private functions

  # Helper to apply a function to all services and return a map
  defp for_all_services(func) do
    @services
    |> Enum.map(&{&1, func.(&1)})
    |> Map.new()
  end

  defp get_producer_module(service) do
    service
    |> get_broadway_module()
    |> Module.concat(Producer)
  end

  defp get_broadway_module(:analyzer), do: Reencodarr.Analyzer.Broadway
  defp get_broadway_module(:crf_searcher), do: Reencodarr.CrfSearcher.Broadway
  defp get_broadway_module(:encoder), do: Reencodarr.Encoder.Broadway

  defp count_work_available(:analyzer) do
    Reencodarr.Media.count_videos_needing_analysis()
  rescue
    _ -> 0
  end

  defp count_work_available(:crf_searcher) do
    Reencodarr.Media.count_videos_for_crf_search()
  rescue
    _ -> 0
  end

  defp count_work_available(:encoder) do
    count_videos_crf_searched()
  rescue
    _ -> 0
  end

  # Count videos in crf_searched state (for encoder)
  defp count_videos_crf_searched do
    import Ecto.Query

    Reencodarr.Repo.aggregate(
      from(v in Reencodarr.Media.Video, where: v.state == :crf_searched),
      :count
    )
  end
end
