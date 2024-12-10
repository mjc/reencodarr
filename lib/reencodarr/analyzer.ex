defmodule Reencodarr.Analyzer do
  use GenServer
  require Logger
  alias Reencodarr.Media

  @concurrent_files 5

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @spec init(any()) :: {:ok, []}
  def init(_) do
    {:ok, []}
  end

  @spec handle_info(map(), list(String.t())) :: {:noreply, list(String.t())}
  def handle_info(%{path: path}, state) when length(state) < @concurrent_files do
    Logger.debug("Video file found: #{path}")
    {:noreply, state ++ [path]}
  end

  def handle_info(%{path: path}, state) do
    Logger.debug("Enough videos found, processing #{Enum.count(state) + 1} videos")
    process_paths(state ++ [path])
  end

  @spec process_path(String.t()) :: :ok
  def process_path(path) do
    GenServer.cast(__MODULE__, {:process_path, path})
  end

  @spec handle_cast({:process_path, String.t()}, list(String.t())) :: {:noreply, list(String.t())}
  def handle_cast({:process_path, path}, state) when length(state) < @concurrent_files do
    Logger.debug("Video file found: #{path}")
    {:noreply, state ++ [path]}
  end

  def handle_cast({:process_path, path}, state) do
    Logger.debug("Video file found: #{path}")
    process_paths(state ++ [path])
  end

  @spec process_paths(list(String.t())) :: {:noreply, list(String.t())}
  defp process_paths(state) do
    paths = Enum.take(state, 5)

    case fetch_mediainfo(paths) do
      {:ok, mediainfo_map} ->
        upsert_videos(paths, mediainfo_map)

      {:error, reason} ->
        Enum.each(paths, fn path ->
          Logger.error("Failed to fetch mediainfo for #{path}: #{reason}")
        end)
    end

    {:noreply, Enum.drop(state, @concurrent_files)}
  end

  @spec upsert_videos(list(String.t()), map()) :: :ok
  defp upsert_videos(paths, mediainfo_map) do
    Enum.each(paths, fn path ->
      mediainfo = Map.get(mediainfo_map, path)

      case Media.upsert_video(%{path: path, mediainfo: mediainfo}) do
        {:ok, _video} -> :ok
        {:error, reason} -> Logger.error("Failed to upsert video for #{path}: #{inspect(reason)}")
      end
    end)
  end

  @spec fetch_mediainfo(list(String.t())) :: {:ok, map()} | {:error, any()}
  defp fetch_mediainfo(paths) do
    paths = List.wrap(paths)

    with {json, 0} <- System.cmd("mediainfo", ["--Output=JSON" | paths]),
         {:ok, mediainfo} <- decode_and_parse_json(json) do
      {:ok, mediainfo}
    else
      {:error, reason} -> {:error, reason}
      {error, _} -> {:error, error}
    end
  end

  @spec decode_and_parse_json(String.t()) :: {:ok, map()} | {:error, :invalid_json}
  defp decode_and_parse_json(json) do
    case Jason.decode(json) do
      {:ok, decoded_json} ->
        {:ok, parse_mediainfo(decoded_json)}

      error ->
        Logger.error("Failed to decode JSON: #{inspect(error)}")
        {:error, :invalid_json}
    end
  end

  @spec parse_mediainfo(map()) :: map()
  defp parse_mediainfo(json) when is_list(json) do
    Enum.map(json, fn
      %{"media" => %{"@ref" => ref}} = mediainfo -> {ref, mediainfo}
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.into(%{})
  end

  defp parse_mediainfo(%{"media" => %{"@ref" => ref}} = json), do: %{ref => json}

  defp parse_mediainfo(_json), do: %{}
end
