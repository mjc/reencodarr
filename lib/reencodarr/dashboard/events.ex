defmodule Reencodarr.Dashboard.Events do
  @moduledoc """
  Dashboard event broadcasting system using Phoenix PubSub.

  Provides a unified interface for broadcasting dashboard events to subscribers,
  with optional data payloads and automatic event name normalization.
  """

  @dashboard_channel "dashboard"

  @doc """
  Broadcast a dashboard event with optional data.

  Event names are automatically normalized to atoms, and data defaults to an empty map.
  """
  def broadcast_event(event_name, data \\ %{}) when is_map(data) do
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, @dashboard_channel, {event_name, data})
  end

  def channel, do: @dashboard_channel
end
