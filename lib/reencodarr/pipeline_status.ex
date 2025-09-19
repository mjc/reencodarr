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
  Broadcast the current status of a service based on its Broadway process state and work availability.
  """
  @spec broadcast_current_status(service()) :: :ok
  def broadcast_current_status(service) do
    case get_service_status(service) do
      :stopped -> broadcast_stopped(service)
      :running -> broadcast_running(service)
      :idle -> broadcast_idle(service)
    end

    :ok
  end

  @doc """
  Get the current status of a service without broadcasting.
  """
  @spec get_service_status(service()) :: :stopped | :running | :idle
  def get_service_status(service) do
    broadway_module = get_broadway_module(service)

    case Process.whereis(broadway_module) do
      nil -> :stopped
      _pid -> determine_running_status(service, broadway_module)
    end
  end

  # Private functions

  defp determine_running_status(service, broadway_module) do
    if broadway_module.running?() do
      if has_work_available?(service) do
        :running
      else
        :idle
      end
    else
      :stopped
    end
  end

  defp broadcast_stopped(:analyzer), do: Events.analyzer_stopped()
  defp broadcast_stopped(:crf_searcher), do: Events.crf_searcher_stopped()
  defp broadcast_stopped(:encoder), do: Events.encoder_stopped()

  defp broadcast_running(:analyzer), do: Events.analyzer_started()
  defp broadcast_running(:crf_searcher), do: Events.crf_searcher_started()
  defp broadcast_running(:encoder), do: Events.encoder_started()

  defp broadcast_idle(:analyzer), do: Events.analyzer_idle()
  defp broadcast_idle(:crf_searcher), do: Events.crf_searcher_idle()
  defp broadcast_idle(:encoder), do: Events.encoder_idle()

  defp get_broadway_module(:analyzer), do: Reencodarr.Analyzer.Broadway
  defp get_broadway_module(:crf_searcher), do: Reencodarr.CrfSearcher.Broadway
  defp get_broadway_module(:encoder), do: Reencodarr.Encoder.Broadway

  defp has_work_available?(:analyzer) do
    Reencodarr.Media.count_videos_needing_analysis() > 0
  rescue
    _ -> false
  end

  defp has_work_available?(:crf_searcher) do
    Reencodarr.Media.count_videos_for_crf_search() > 0
  rescue
    _ -> false
  end

  defp has_work_available?(:encoder) do
    # Count videos in crf_searched state
    import Ecto.Query

    Reencodarr.Repo.aggregate(
      from(v in Reencodarr.Media.Video, where: v.state == :crf_searched),
      :count
    ) > 0
  rescue
    _ -> false
  end
end
