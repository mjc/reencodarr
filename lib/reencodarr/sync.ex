defmodule Reencodarr.Media.VideoFileInfo do
  @moduledoc false
  defstruct [
    :path,
    :size,
    :service_id,
    :service_type,
    :audio_codec,
    :bitrate,
    :audio_channels,
    :video_codec,
    :resolution,
    :video_fps,
    :video_dynamic_range,
    :video_dynamic_range_type,
    :audio_stream_count,
    :overall_bitrate,
    :run_time,
    :subtitles,
    :title
  ]
end

defmodule Reencodarr.Sync do
  use GenServer
  require Logger
  alias Reencodarr.{Media, Services}

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def sync_episodes, do: GenServer.cast(__MODULE__, :sync_episodes)
  def sync_movies, do: GenServer.cast(__MODULE__, :sync_movies)

  def init(state), do: {:ok, state}

  def handle_cast(:refresh_and_rename_series, state) do
    Task.start(fn -> Services.Sonarr.refresh_and_rename_all_series() end)
    {:noreply, state}
  end

  def handle_cast(action, state) when action in [:sync_episodes, :sync_movies] do
    {get_items, get_files, service_type} =
      case action do
        :sync_episodes -> {&Services.get_shows/0, &Services.get_episode_files/1, :sonarr}
        :sync_movies -> {&Services.get_movies/0, &Services.get_movie_files/1, :radarr}
      end

    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "progress", {:sync, :started})

    Task.start(fn ->
      case get_items.() do
        {:ok, %Req.Response{body: items}} when is_list(items) ->
          items_count = length(items)
          batch_size = 50

          items
          |> Stream.chunk_every(batch_size)
          |> Stream.with_index()
          |> Stream.each(fn {batch, batch_index} ->
            batch
            |> Task.async_stream(&fetch_and_upsert_files(&1["id"], get_files, service_type),
              max_concurrency: 10,
              timeout: 60_000,
              on_timeout: :kill_task
            )
            |> Stream.with_index(batch_index * batch_size)
            |> Stream.each(fn {res, idx} ->
              progress = div((idx + 1) * 100, items_count)

              Phoenix.PubSub.broadcast(
                Reencodarr.PubSub,
                "progress",
                {:sync, :progress, progress}
              )

              if !match?({:ok, :ok}, res), do: Logger.error("Sync error: #{inspect(res)}")
            end)
            |> Stream.run()
          end)
          |> Stream.run()

        _ ->
          Logger.error("Sync error: unexpected response")
      end

      Phoenix.PubSub.broadcast(Reencodarr.PubSub, "progress", {:sync, :complete})
    end)

    {:noreply, state}
  end

  defp fetch_and_upsert_files(id, get_files, service_type) do
    case get_files.(id) do
      {:ok, %Req.Response{body: files}} when is_list(files) ->
        Enum.each(files, &upsert_video_from_file(&1, service_type))

      _ ->
        Logger.error("Fetch files error for id #{inspect(id)}")
    end

    :ok
  end

  def upsert_video_from_file(file, service_type) do
    info = Reencodarr.Media.MediaInfo.video_file_info_from_file(file, service_type)
    if is_nil(info.size), do: Logger.warning("File size is missing: #{inspect(file)}")

    if needs_analysis?(info),
      do:
        Reencodarr.Analyzer.process_path(%{
          path: info.path,
          service_id: info.service_id,
          service_type: info.service_type
        })

    if !needs_analysis?(info) do
      mediainfo = Reencodarr.Media.MediaInfo.from_video_file_info(info)

      Media.upsert_video(%{
        "path" => info.path,
        "size" => info.size,
        "service_id" => info.service_id,
        "service_type" => info.service_type,
        "mediainfo" => mediainfo,
        "bitrate" => info.bitrate
      })
    end

    :ok
  end

  defp needs_analysis?(%{audio_codec: c, bitrate: b}) when c in ["TrueHD", "EAC3"] or b == 0,
    do: true

  defp needs_analysis?(_), do: false

  def refresh_operations(file_id, :sonarr) do
    with {:ok, %Req.Response{body: episode_file}} <- Services.Sonarr.get_episode_file(file_id),
         {:ok, _} <- Services.Sonarr.refresh_series(episode_file["seriesId"]),
         {:ok, _} <- Services.Sonarr.rename_files(episode_file["seriesId"]) do
      {:ok, "Refresh and rename triggered"}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def refresh_operations(file_id, :radarr) do
    with {:ok, %Req.Response{body: movie_file}} <- Services.Radarr.get_movie_file(file_id),
         {:ok, _} <- Services.Radarr.refresh_movie(movie_file["movieId"]),
         # Placeholder for rename
         {:ok, _} <- Services.Radarr.rename_movie_files(movie_file["movieId"]) do
      {:ok, "Refresh triggered for Radarr"}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def refresh_and_rename_from_video(%{service_type: :sonarr, service_id: id}),
    do: refresh_operations(id, :sonarr)

  def refresh_and_rename_from_video(%{service_type: :radarr, service_id: id}),
    do: refresh_operations(id, :radarr)

  def rescan_and_rename_series(id), do: refresh_operations(id, :sonarr)

  def delete_video_and_vmafs(path) do
    case Reencodarr.Media.delete_videos_with_path(path) do
      {:ok, _} -> :ok
      err -> err
    end
  end
end
