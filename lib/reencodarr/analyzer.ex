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

  @spec process_path(map()) :: :ok
  def process_path(video_info) do
    GenServer.cast(__MODULE__, {:process_path, video_info})
  end

  @spec handle_cast({:process_path, map()}, list(map())) :: {:noreply, list(map())}
  def handle_cast({:process_path, video_info}, state) when length(state) < @concurrent_files do
    Logger.debug("Video file found: #{video_info.path}")
    {:noreply, state ++ [video_info]}
  end

  def handle_cast({:process_path, video_info}, state) do
    Logger.debug("Video file found: #{video_info.path}")
    process_paths(state ++ [video_info])
  end

  @spec process_paths(list(map())) :: {:noreply, list(map())}
  defp process_paths(state) do
    paths = Enum.take(state, 5)

    paths =
      Enum.reject(paths, fn %{path: path} ->
        Media.video_exists?(path) &&
          Logger.debug("Video already exists for path: #{path}, skipping.")
      end)

    case fetch_mediainfo(Enum.map(paths, & &1.path)) do
      {:ok, mediainfo_map} ->
        Logger.info("Fetched mediainfo for #{length(paths)} videos")
        upsert_videos(paths, mediainfo_map)

      {:error, reason} ->
        Enum.each(paths, fn %{path: path} ->
          Logger.error("Failed to fetch mediainfo for #{path}: #{reason}")
        end)
    end

    {:noreply, Enum.drop(state, @concurrent_files)}
  end

  @spec upsert_videos(list(map()), map()) :: :ok
  defp upsert_videos(paths, mediainfo_map) do
    Enum.each(paths, &upsert_video(&1, mediainfo_map))
  end

  defp upsert_video(
         %{path: path, service_id: service_id, service_type: service_type},
         mediainfo_map
       ) do
    mediainfo = Map.get(mediainfo_map, path)
    file_size = get_in(mediainfo, ["media", "track", Access.at(0), "FileSize"])

    with size when size not in [nil, ""] <- file_size,
         {:ok, _video} <-
           Media.upsert_video(%{
             path: path,
             mediainfo: mediainfo,
             service_id: service_id,
             service_type: service_type,
             size: file_size
           }) do
      Logger.debug("Upserted analyzed video for #{path}")
      :ok
    else
      nil -> Logger.error("Mediainfo size is empty for #{path}, skipping upsert.")
      "" -> Logger.error("Mediainfo size is empty for #{path}, skipping upsert.")
      {:error, reason} -> Logger.error("Failed to upsert video for #{path}: #{inspect(reason)}")
    end
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
