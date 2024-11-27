defmodule Reencodarr.Analyzer do
  use GenServer
  require Logger
  alias Reencodarr.Media

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def init(_) do
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "video:found")
    {:ok, nil}
  end

  def handle_info(%{path: path, size: size, updated_at: updated_at}, state) do
    Logger.info("Video file found: #{path}, size: #{size}, updated_at: #{updated_at}")
    case fetch_mediainfo(path) do
      {:ok, mediainfo} ->
        Media.upsert_video(%{path: path, size: size, mediainfo: mediainfo})
      {:error, reason} ->
        Logger.error("Failed to fetch mediainfo for #{path}: #{reason}")
    end
    {:noreply, state}
  end

  defp fetch_mediainfo(path) do
    case System.cmd("mediainfo", ["--Output=JSON", path]) do
      {json, 0} ->
        {:ok, Jason.decode!(json)}
      {error, _exit_code} ->
        {:error, error}
    end
  end
end
