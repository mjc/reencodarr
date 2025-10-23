defmodule Reencodarr.Dashboard.Events do
  @moduledoc """
  Dashboard event broadcasting system using Phoenix PubSub.

  Handles all pipeline state transition broadcasting, including:
  - Dashboard UI events via PubSub
  - Internal service communication via PubSub
  """

  @type service :: :analyzer | :crf_searcher | :encoder
  @type pipeline_state :: :stopped | :idle | :running | :processing | :pausing | :paused

  @dashboard_channel "dashboard"

  @doc """
  Broadcast a dashboard event with optional data.

  Event names are automatically normalized to atoms, and data defaults to an empty map.
  """
  def broadcast_event(event_name, data \\ %{}) when is_map(data) do
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, @dashboard_channel, {event_name, data})
  end

  @doc """
  Pipeline state change tracking with internal service broadcasts only.
  Dashboard UI broadcasts removed - LiveView handles state via direct progress events.
  """
  @spec pipeline_state_changed(service(), pipeline_state(), pipeline_state()) ::
          {:ok, pipeline_state()}
  def pipeline_state_changed(service, _from_state, to_state)
      when service in [:analyzer, :crf_searcher, :encoder] do
    # Only internal service PubSub (for service-to-service communication and tests)
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, Atom.to_string(service), {service, to_state})

    {:ok, to_state}
  end

  def channel, do: @dashboard_channel
end
