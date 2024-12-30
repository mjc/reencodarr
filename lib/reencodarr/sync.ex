defmodule Reencodarr.Sync do
  @moduledoc """
  This module is responsible for syncing data between services and Reencodarr.
  """
  use GenServer
  require Logger
  alias Reencodarr.{Media, Services, Media.CodecMapper, Media.CodecHelper}

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec sync_episodes :: :ok
  def sync_episodes do
    GenServer.cast(__MODULE__, :sync_episodes)
  end

  @spec sync_movies :: :ok
  def sync_movies do
    GenServer.cast(__MODULE__, :sync_movies)
  end

  # Server Callbacks
  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  @spec handle_cast(:sync_episodes | :sync_movies, map()) :: {:noreply, map()}
  def handle_cast(action, state) when action in [:sync_episodes, :sync_movies] do
    {get_items_fun, get_files_fun, service_type} =
      case action do
        :sync_episodes ->
          {&Services.get_shows/0, &Services.get_episode_files/1, :sonarr}

        :sync_movies ->
          {&Services.get_movies/0, &Services.get_movie_files/1, :radarr}
      end

    do_sync(state, get_items_fun, get_files_fun, service_type)
  end

  @spec do_sync(
          map(),
          (-> {:ok, any()} | {:error, any()}),
          (any() -> {:ok, any()} | {:error, any()}),
          atom()
        ) ::
          {:noreply, map()}
  defp do_sync(state, get_items_fun, get_files_fun, service_type) do
    case get_items_fun.() do
      {:ok, %Req.Response{body: items}} when is_list(items) ->
        items_count = length(items)

        items
        |> Task.async_stream(
          fn item ->
            fetch_and_upsert_files(item["id"], get_files_fun, service_type)
          end,
          max_concurrency: 5,
          on_timeout: :kill_task,
          timeout: 60_000  # Increased timeout to 60 seconds
        )
        |> Stream.with_index()
        |> Enum.each(fn {task_result, index} ->
          case task_result do
            {:ok, :ok} ->
              progress = div((index + 1) * 100, items_count)
              Logger.debug("Sync progress: #{progress}%")
              Phoenix.PubSub.broadcast(Reencodarr.PubSub, "progress", {:sync_progress, progress})

            {:ok, other} ->
              # Handle any other success value if needed
              Logger.error("Unexpected success value: #{inspect(other)}")

            {:error, reason} ->
              Logger.error("Error in concurrent sync: #{inspect(reason)}")

            {:exit, reason} ->
              Logger.error("Task exited with reason: #{inspect(reason)}")

            _ ->
              Logger.error("Unknown task result: #{inspect(task_result)}")
          end
        end)

      {:ok, _other} ->
        Logger.error("Unexpected format for fetched items")

      {:error, reason} ->
        Logger.error("Sync error: #{inspect(reason)}")
    end

    Phoenix.PubSub.broadcast(Reencodarr.PubSub, "progress", :sync_complete)
    {:noreply, state}
  end

  @spec fetch_and_upsert_files(any(), (any() -> {:ok, any()} | {:error, any()}), atom()) :: :ok
  defp fetch_and_upsert_files(id, get_files_fun, service_type) do
    case get_files_fun.(id) do
      {:ok, %Req.Response{body: files}} when is_list(files) ->
        Enum.each(files, &upsert_video_from_file(&1, service_type))

      {:ok, _other} ->
        Logger.error("Unexpected format for fetched files")

      {:error, reason} ->
        Logger.error("Fetch files error: #{inspect(reason)}")
    end

    :ok
  end

  @spec upsert_video_from_file(map(), atom()) :: :ok
  defp upsert_video_from_file(file, service_type) do
    audio_codec = CodecMapper.map_codec_id(file["mediaInfo"]["audioCodec"])

    mediainfo = %{
      "media" => %{
        "track" => [
          %{
            "@type" => "General",
            "AudioCount" => file["mediaInfo"]["audioStreamCount"],
            "OverallBitRate" =>
              file["mediaInfo"]["overallBitrate"] ||
                file["mediaInfo"]["videoBitrate"],
            "Duration" => CodecHelper.parse_duration(file["mediaInfo"]["runTime"]),
            "FileSize" => file["size"],
            "TextCount" => length(String.split(file["mediaInfo"]["subtitles"], "/")),
            "VideoCount" => 1,
            "Title" => file["title"]
          },
          %{
            "@type" => "Video",
            "FrameRate" => file["mediaInfo"]["videoFps"],
            "Height" =>
              String.split(file["mediaInfo"]["resolution"], "x")
              |> List.last()
              |> String.to_integer(),
            "Width" =>
              String.split(file["mediaInfo"]["resolution"], "x")
              |> List.first()
              |> String.to_integer(),
            "HDR_Format" => file["mediaInfo"]["videoDynamicRange"],
            "HDR_Format_Compatibility" => file["mediaInfo"]["videoDynamicRangeType"],
            "CodecID" => CodecMapper.map_codec_id(file["mediaInfo"]["videoCodec"])
          },
          %{
            "@type" => "Audio",
            "CodecID" => audio_codec,
            "Channels" => to_string(CodecMapper.map_channels(file["mediaInfo"]["audioChannels"])),
            "Format_Commercial_IfAny" => CodecMapper.format_commercial_if_any(audio_codec)
          }
        ]
      }
    }

    bitrate =
      file["mediaInfo"]["overallBitrate"] || file["mediaInfo"]["videoBitrate"]

    attrs = %{
      "path" => file["path"],
      "size" => file["size"],
      "service_id" => to_string(file["id"]),
      "service_type" => service_type,
      "mediainfo" => mediainfo,
      "bitrate" => bitrate
    }

    if is_nil(file["size"]) do
      Logger.warning("File size is missing for file: #{inspect(file)}")
    end

    if audio_codec in ["TrueHD", "EAC3"] or bitrate == 0 do
      Reencodarr.Analyzer.process_path(%{
        path: file["path"],
        service_id: to_string(file["id"]),
        service_type: service_type
      })
    else
      Media.upsert_video(attrs)
    end

    :ok
  end

  def refresh_operations(file_id, :sonarr) do
    with {:ok, %Req.Response{body: episode_file}} <- Services.Sonarr.get_episode_file(file_id),
         {:ok, _refresh_series} <- Services.Sonarr.refresh_series(episode_file["seriesId"]),
         {:ok, _rename_files} <- Services.Sonarr.rename_files(episode_file["seriesId"]) do
      {:ok, "Refresh and rename triggered successfully"}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def refresh_and_rename_from_video(%{service_type: :sonarr, service_id: id}),
    do: refresh_operations(id, :sonarr)

  # rescan the whole series and rename all files for that series. use carefully
  def rescan_and_rename_series(episode_file_id),
    do: refresh_operations(episode_file_id, :sonarr)
end
