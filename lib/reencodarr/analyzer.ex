defmodule Reencodarr.Analyzer do
  use GenServer
  require Logger
  alias Reencodarr.Media

  @concurrent_files 5
  @process_interval :timer.seconds(10)
  @adjustment_interval :timer.minutes(1)
  @min_concurrency 1
  @max_concurrency 1000

  @kp 0.1  # Proportional gain
  @ki 0.01 # Integral gain
  @kd 0.05 # Derivative gain

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @spec init(any()) :: {:ok, %{
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
    {:ok, %{
      queue: [],
      concurrency: @concurrent_files,
      processed_timestamps: [],
      last_adjustment: :os.system_time(:second),
      pid_integral: 0.0,
      previous_error: 0.0,
      max_throughput: 0
    }}
  end

  @spec handle_info(:process_queue, map()) :: {:noreply, map()}
  def handle_info(:process_queue, state) do
    if length(state.queue) > 0 do
      Logger.debug("Processing queue with #{length(state.queue)} videos.")
      {:noreply, new_state} = process_paths(state) # Capture the updated state
      schedule_process()
      {:noreply, new_state} # Return the updated state
    else
      schedule_process()
      {:noreply, state}
    end
  end

  @spec handle_info(:adjust_concurrency, map()) :: {:noreply, map()}
  def handle_info(:adjust_concurrency, state) do
    new_state = adjust_concurrency(state)
    schedule_adjustment()
    {:noreply, new_state}
  end

  @spec handle_info(map(), map()) :: {:noreply, map()}
  def handle_info(%{path: path}, state) do
    Logger.debug("Video file found: #{path}. Queue size: #{length(state.queue) + 1}")
    {:noreply, %{state | queue: state.queue ++ [path]}}
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
    Logger.debug("Video file found: #{video_info.path}. Queue size: #{length(state.queue) + 1}")
    {:noreply, %{state | queue: state.queue ++ [video_info]}}
  end

  @spec process_paths(map()) :: {:noreply, map()}
  defp process_paths(%{queue: queue, concurrency: concurrency} = state) do
    paths = Enum.take(queue, concurrency)

    new_state =
      case fetch_mediainfo(Enum.map(paths, & &1.path)) do
        {:ok, mediainfo_map} ->
          Logger.info("Fetched mediainfo for #{length(paths)} videos. Queue size: #{length(queue)}")
          upsert_videos(paths, mediainfo_map)
          update_throughput_timestamps(state, length(paths))

        {:error, reason} ->
          Enum.each(paths, fn %{path: path} ->
            Logger.error(
              "Failed to fetch mediainfo for #{path}: #{reason}. Queue size: #{length(queue)}"
            )
          end)
          state
      end

    {:noreply, %{new_state | queue: Enum.drop(queue, concurrency)}}
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

  defp update_throughput_timestamps(state, processed_count) do
    now = :os.system_time(:second)
    updated_ts = Enum.concat(List.duplicate(now, processed_count), state.processed_timestamps)
                  |> Enum.filter(&(&1 >= now - 60)) # Changed back from 3600 to 60 seconds
    new_throughput = length(updated_ts)
    new_max = max(state.max_throughput, new_throughput)
    %{state | processed_timestamps: updated_ts, max_throughput: new_max}
  end

  defp adjust_concurrency(state) do
    now = :os.system_time(:second)
    throughput = length(state.processed_timestamps)
    error = (state.max_throughput + 1) - throughput

    # Update integral
    pid_integral = state.pid_integral + error

    # Calculate derivative
    derivative = error - state.previous_error

    # Compute PID output
    pid_output = @kp * error + @ki * pid_integral + @kd * derivative

    # Determine concurrency adjustment
    concurrency_change = round(pid_output)

    # Calculate new concurrency ensuring it stays within bounds
    new_concurrency =
      state.concurrency + concurrency_change
      |> max(@min_concurrency)
      |> min(@max_concurrency)

    Logger.info("Adjusting concurrency to #{new_concurrency} based on throughput of #{throughput} files/min (PID output: #{pid_output}, max_throughput: #{state.max_throughput})")

    %{state |
      concurrency: new_concurrency,
      pid_integral: pid_integral,
      previous_error: error,
      last_adjustment: now
    }
  end
end
