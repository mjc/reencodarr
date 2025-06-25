defmodule Reencodarr.Analyzer do
  use GenServer
  require Logger
  alias Reencodarr.Media

  @concurrent_files 5
  @process_interval :timer.seconds(10)
  @adjustment_interval :timer.minutes(1)
  @min_concurrency 1
  @max_concurrency 100

  # Proportional gain
  @kp 0.1
  # Integral gain
  @ki 0.01
  # Derivative gain
  @kd 0.05

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @spec init(any()) ::
          {:ok,
           %{
             queue: list(map()),
             concurrency: integer,
             processed_timestamps: list(pos_integer),
             last_adjustment: pos_integer,
             pid_integral: float,
             previous_error: float,
             max_throughput: non_neg_integer
           }}
  def init(_) do
    schedule_process()
    schedule_adjustment()

    {:ok,
     %{
       queue: [],
       concurrency: @concurrent_files,
       processed_timestamps: [],
       last_adjustment: :os.system_time(:second),
       pid_integral: 0.0,
       previous_error: 0.0,
       max_throughput: 0
     }}
  end

  # Use pattern matching to separate empty vs. non-empty queue
  def handle_info(:process_queue, %{queue: []} = state) do
    schedule_process()
    {:noreply, state}
  end

  def handle_info(:process_queue, %{queue: _queue} = state) do
    Logger.debug("Processing queue with #{length(state.queue)} videos.")
    {:noreply, new_state} = process_paths(state)
    schedule_process()
    {:noreply, new_state}
  end

  def handle_info(:adjust_concurrency, %{queue: []} = state) do
    schedule_adjustment()
    {:noreply, state}
  end

  @spec handle_info(:adjust_concurrency, map()) :: {:noreply, map()}
  def handle_info(:adjust_concurrency, state) do
    new_state = adjust_concurrency(state)
    schedule_adjustment()
    {:noreply, new_state}
  end

  @spec handle_info(map(), map()) :: {:noreply, map()}
  def handle_info(%{path: path, force_reanalyze: force_reanalyze} = msg, state) do
    video = Media.get_video_by_path(path)

    if video == nil or video.bitrate == 0 or force_reanalyze do
      Logger.debug("Adding new video to queue: #{path}. Queue size: #{length(state.queue) + 1}")
      {:noreply, %{state | queue: state.queue ++ [msg]}}
    else
      Logger.debug(
        "Video already exists with non-zero bitrate, skipping: #{path}. Queue size: #{length(state.queue)}"
      )

      {:noreply, state}
    end
  end

  defp schedule_process do
    Process.send_after(self(), :process_queue, @process_interval)
  end

  defp schedule_adjustment do
    Process.send_after(self(), :adjust_concurrency, @adjustment_interval)
  end

  @spec process_path(map()) :: :ok
  def process_path(video_info) do
    GenServer.cast(__MODULE__, {:process_path, video_info})
  end

  @spec handle_cast({:process_path, map()}, map()) :: {:noreply, map()}
  def handle_cast({:process_path, video_info}, state) do
    video = Media.get_video_by_path(video_info.path)

    if video == nil or video.bitrate == 0 or Map.get(video_info, :force_reanalyze, false) do
      Logger.debug(
        "Adding new video to queue: #{video_info.path}. Queue size: #{length(state.queue) + 1}"
      )

      {:noreply, %{state | queue: state.queue ++ [video_info]}}
    else
      Logger.debug(
        "Video already exists with non-zero bitrate, skipping: #{video_info.path}. Queue size: #{length(state.queue)}"
      )

      {:noreply, state}
    end
  end

  @spec process_paths(map()) :: {:noreply, map()}
  defp process_paths(%{queue: queue, concurrency: concurrency} = state) do
    {paths, remaining} = Enum.split(queue, concurrency)

    start_time = :os.system_time(:second)
    res = fetch_mediainfo(Enum.map(paths, & &1.path))
    end_time = :os.system_time(:second)
    duration = end_time - start_time

    new_state =
      case res do
        {:ok, mediainfo_map} ->
          if duration > 60 do
            partial_count = round(length(paths) * 60 / duration)

            Logger.warning(
              "Mediainfo fetch took more than a minute, adjusting concurrency to #{partial_count}"
            )

            %{state | concurrency: partial_count}
          else
            upsert_videos(paths, mediainfo_map)
            update_throughput_timestamps(state, length(paths))
          end

        {:error, reason} ->
          log_fetch_error(paths, reason, queue)
          state
      end

    {:noreply, %{new_state | queue: remaining}}
  end

  defp log_fetch_error(paths, reason, queue) do
    Enum.each(paths, fn %{path: path} ->
      Logger.error(
        "Failed to fetch mediainfo for #{path}: #{reason}. Queue size: #{length(queue)}"
      )
    end)
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
    paths
    |> List.wrap()
    |> run_mediainfo_cmd()
    |> decode_and_parse_json()
  end

  defp run_mediainfo_cmd([]), do: {:ok, %{}}

  defp run_mediainfo_cmd(paths) do
    case System.cmd("mediainfo", ["--Output=JSON" | paths]) do
      {json, 0} -> {:ok, json}
      {error_msg, _code} -> {:error, error_msg}
    end
  end

  @spec decode_and_parse_json({:ok, String.t()} | {:error, any()}) ::
          {:ok, map()} | {:error, any()}
  defp decode_and_parse_json({:ok, json}) do
    with {:ok, decoded} <- Jason.decode(json) do
      {:ok, parse_mediainfo(decoded)}
    else
      error ->
        Logger.error("Failed to decode JSON: #{inspect(error)}")
        {:error, :invalid_json}
    end
  end

  defp decode_and_parse_json({:error, reason}), do: {:error, reason}

  @spec parse_mediainfo(map() | list()) :: map()
  defp parse_mediainfo(json) when is_list(json) do
    json
    |> Enum.map(fn
      %{"media" => %{"@ref" => ref}} = mediainfo -> {ref, mediainfo}
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.into(%{})
  end

  defp parse_mediainfo(%{"media" => %{"@ref" => ref}} = json), do: %{ref => json}
  defp parse_mediainfo(_), do: %{}

  defp update_throughput_timestamps(state, processed_count) do
    now = :os.system_time(:second)
    new_stamps = List.duplicate(now, processed_count) ++ state.processed_timestamps
    updated_ts = Enum.filter(new_stamps, &(&1 >= now - 60))
    new_throughput = length(updated_ts)
    new_max = max(state.max_throughput, new_throughput)

    # Emit telemetry event
    Reencodarr.Telemetry.emit_analyzer_throughput(new_throughput, length(state.queue))

    %{state | processed_timestamps: updated_ts, max_throughput: new_max}
  end

  defp adjust_concurrency(%{processed_timestamps: timestamps, max_throughput: mt} = state) do
    throughput = length(timestamps)

    # Prevent error from going negative (which might continually raise concurrency)
    error =
      if throughput >= mt + 1 do
        0
      else
        mt + 1 - throughput
      end

    pid_integral = state.pid_integral + error
    derivative = error - state.previous_error
    pid_output = @kp * error + @ki * pid_integral + @kd * derivative

    concurrency_change = round(pid_output)

    new_concurrency =
      (state.concurrency + concurrency_change)
      |> max(@min_concurrency)
      |> min(@max_concurrency)

    if new_concurrency != state.concurrency do
      Logger.info("""
      Adjusting concurrency to #{new_concurrency} based on throughput of #{throughput} files/min \
      (PID output: #{pid_output}, max_throughput: #{mt})
      """)
    end

    %{
      state
      | concurrency: new_concurrency,
        pid_integral: pid_integral,
        previous_error: error,
        last_adjustment: :os.system_time(:second)
    }
  end

  def reanalyze_video(video_id) do
    %{path: path, service_id: service_id, service_type: service_type} = Media.get_video!(video_id)

    process_path(%{
      path: path,
      service_id: service_id,
      service_type: service_type,
      force_reanalyze: true
    })
  end
end
