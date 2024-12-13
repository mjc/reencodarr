defmodule Reencodarr.Statistics do
  use GenServer
  alias Reencodarr.Media

  @update_interval 5_000

  def start_link(_) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def init(:ok) do
    schedule_update()
    {:ok, %{media_stats: %Media.Stats{}}}
  end

  def handle_info(:update_stats, _state) do
    media_stats = Media.fetch_stats()
    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "stats", {:stats, media_stats})
    schedule_update()
    {:noreply, %{media_stats: media_stats}}
  end

  defp schedule_update do
    Process.send_after(self(), :update_stats, @update_interval)
  end

  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  def handle_call(:get_stats, _from, state) do
    {:reply, state, state}
  end
end
