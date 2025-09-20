defmodule Reencodarr.Dashboard.Events do
  @moduledoc """
  Centralized PubSub event system for dashboard updates.
  """

  alias Phoenix.PubSub

  @dashboard_channel "dashboard"

  # Single broadcast function - just pass the event name and data
  def broadcast_event(event, data \\ %{}), do: broadcast({event, data})

  @doc "Get the dashboard channel name for subscriptions"
  def channel, do: @dashboard_channel

  # Simple broadcast helper
  defp broadcast(message) do
    PubSub.broadcast(Reencodarr.PubSub, @dashboard_channel, message)
  end
end
