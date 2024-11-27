defmodule Reencodarr.Analyzer do
  use GenServer
  require Logger
  alias Reencodarr.Media

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def init(_) do
    {:ok, [], {:continue, :subscribe}}
  end

  def handle_continue(:subscribe, state) do
    Phoenix.PubSub.subscribe(Reencodarr.PubSub, "video:found")
    {:noreply, state}
  end

  def handle_info(%{path: path, size: size, updated_at: updated_at}, state) do
    Logger.debug("Video file found: #{path}, size: #{size}, updated_at: #{updated_at}")

    new_state = update_state_with_path(state, path)

    if length(new_state) >= 5 do
      paths = Enum.take(new_state, 5)
      case fetch_mediainfo(paths) do
        {:ok, mediainfo_map} ->
          Enum.each(paths, fn path ->
            mediainfo = Map.get(mediainfo_map, path)
            Media.upsert_video(%{path: path, size: size, mediainfo: mediainfo})
          end)
        {:error, reason} ->
          Enum.each(paths, fn path ->
            Logger.error("Failed to fetch mediainfo for #{path}: #{reason}")
          end)
      end
      {:noreply, Enum.drop(new_state, 5)}
    else
      {:noreply, new_state}
    end
  end

  defp update_state_with_path(state, path) do
    state ++ [path]
  end

  def fetch_mediainfo(paths) when is_list(paths) do
    System.cmd("mediainfo", ["--Output=JSON" | paths])
    |> case do
      {json, 0} ->
        json = Jason.decode!(json)
        json = Enum.map(json, fn mediainfo -> {mediainfo["media"]["@ref"], mediainfo} end) |> Enum.into(%{})
        {:ok, json}
      {error, _} -> {:error, error}
    end
  end

  def fetch_mediainfo(path) do
    System.cmd("mediainfo", ["--Output=JSON", path])
    |> case do
      {json, 0} -> {:ok, Jason.decode!(json)}
      {error, _} -> {:error, error}
    end
  end

end
