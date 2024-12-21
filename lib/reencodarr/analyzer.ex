defmodule Reencodarr.Analyzer do
  use GenServer
  require Logger
  alias Reencodarr.Media

  @concurrent_files 5
  @process_interval :timer.seconds(10)

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @spec init(any()) :: {:ok, []}
  def init(_) do
    schedule_process()
    {:ok, []}
  end

  @spec handle_info(:process_queue, list(String.t())) :: {:noreply, list(String.t())}
  def handle_info(:process_queue, state) do
    if length(state) > 0 do
      Logger.debug("Processing queue with #{length(state)} videos.")
      process_paths(state)
    end
    schedule_process()
    {:noreply, state}
  end

  @spec handle_info(map(), list(String.t())) :: {:noreply, list(String.t())}
  def handle_info(%{path: path}, state) do
    Logger.debug("Video file found: #{path}. Queue size: #{length(state) + 1}")
    {:noreply, state ++ [path]}
  end

  defp schedule_process do
    Process.send_after(self(), :process_queue, @process_interval)
  end

  @spec process_path(map()) :: :ok
  def process_path(video_info) do
    GenServer.cast(__MODULE__, {:process_path, video_info})
  end

  @spec handle_cast({:process_path, map()}, list(map())) :: {:noreply, list(map())}
  def handle_cast({:process_path, video_info}, state) do
    Logger.debug("Video file found: #{video_info.path}. Queue size: #{length(state) + 1}")
    {:noreply, state ++ [video_info]}
  end

  @spec process_paths(list(map())) :: {:noreply, list(map())}
  defp process_paths(state) do
    paths = Enum.take(state, @concurrent_files)

    # paths =
    #   Enum.reject(paths, fn %{path: path} ->
    #     Media.video_exists?(path) &&
    #       Logger.debug("Video already exists for path: #{path}, skipping.")
    #   end)

    case fetch_mediainfo(Enum.map(paths, & &1.path)) do
      {:ok, mediainfo_map} ->
        Logger.info("Fetched mediainfo for #{length(paths)} videos. Queue size: #{length(state)}")
        upsert_videos(paths, mediainfo_map)

      {:error, reason} ->
        Enum.each(paths, fn %{path: path} ->
          Logger.error(
            "Failed to fetch mediainfo for #{path}: #{reason}. Queue size: #{length(state)}"
          )
        end)
    end

    {:noreply, Enum.drop(state, @concurrent_files)}
  end

  @spec upsert_videos(list(map()), map()) :: :ok
  defp upsert_videos(paths, mediainfo_map) do
    Enum.each(paths, &upsert_video(&1, mediainfo_map, length(paths)))
  end

  defp upsert_video(
         %{path: path, service_id: service_id, service_type: service_type},
         mediainfo_map,
         queue_length
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
      Logger.debug("Upserted analyzed video for #{path}. Queue size: #{queue_length}")
      :ok
    else
      nil ->
        Logger.error(
          "Mediainfo size is empty for #{path}, skipping upsert. Queue size: #{queue_length}"
        )

      "" ->
        Logger.error(
          "Mediainfo size is empty for #{path}, skipping upsert. Queue size: #{queue_length}"
        )

      {:error, reason} ->
        Logger.error(
          "Failed to upsert video for #{path}: #{inspect(reason)}. Queue size: #{queue_length}"
        )
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
