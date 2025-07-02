defmodule Reencodarr.Analyzer.Broadway do
  @moduledoc """
  Broadway pipeline for video analysis operations.

  This module replaces the GenStage-based analyzer with a Broadway pipeline
  that provides better observability, fault tolerance, and scalability.
  """

  use Broadway
  require Logger

  alias Reencodarr.{Media, Telemetry}
  alias Broadway.Message

  @doc """
  Start the Broadway pipeline.
  """
  def start_link(_opts) do
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {Reencodarr.Analyzer.Broadway.Producer, []},
        transformer: {__MODULE__, :transform, []},
        rate_limiting: [
          allowed_messages: 50,
          interval: 1000
        ]
      ],
      processors: [
        default: [
          concurrency: 5,
          max_demand: 10
        ]
      ],
      batchers: [
        default: [
          batch_size: 10,
          batch_timeout: 5_000,
          concurrency: 1
        ]
      ],
      context: %{
        concurrent_files: 5,
        processing_timeout: :timer.minutes(5)
      }
    )
  end

  @doc """
  Add a video to the pipeline for processing.
  """
  def process_path(video_info) do
    GenStage.cast(Reencodarr.Analyzer.Broadway.Producer, {:add_video, video_info})
  end

  @doc """
  Check if the analyzer is running.
  """
  def running? do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  @doc """
  Pause the analyzer.
  """
  def pause do
    GenStage.cast(Reencodarr.Analyzer.Broadway.Producer, :pause)
  end

  @doc """
  Resume the analyzer.
  """
  def resume do
    GenStage.cast(Reencodarr.Analyzer.Broadway.Producer, :resume)
  end

  # Alias for API compatibility
  def start, do: resume()

  @doc """
  Get current manual queue for dashboard display.
  """
  def get_manual_queue do
    GenStage.call(Reencodarr.Analyzer.Broadway.Producer, :get_manual_queue)
  rescue
    _ -> []
  end

  @impl Broadway
  def handle_message(_processor_name, message, _context) do
    # Individual messages are just passed through to be batched
    message
  end

  @impl Broadway
  def handle_batch(:default, messages, _batch_info, context) do
    start_time = System.monotonic_time(:millisecond)
    batch_size = length(messages)

    Logger.info("Processing batch of #{batch_size} videos")

    # Extract video_infos from messages
    video_infos = Enum.map(messages, &(&1.data))

    # Process the batch using existing logic from the GenStage consumer
    process_batch(video_infos, context)

    # Log completion and emit telemetry
    duration = System.monotonic_time(:millisecond) - start_time
    Logger.info("Completed batch of #{batch_size} videos in #{duration}ms")
    Telemetry.emit_analyzer_throughput(batch_size, 0)

    # Since process_batch always returns :ok, all messages are successful
    messages
  end

  @doc """
  Transform raw video info into a Broadway message.
  """
  def transform(event, _opts) do
    %Message{
      data: event,
      acknowledger: {__MODULE__, :ack_id, :ack_data}
    }
  end

  @doc """
  Handle message acknowledgment.
  """
  def ack(:ack_id, _successful, failed) do
    if length(failed) > 0 do
      Logger.warning("Failed to process #{length(failed)} video analysis messages")
    end

    :ok
  end

  # Private functions - ported from the GenStage consumer

  defp process_batch(video_infos, _context) do
    video_infos
    |> fetch_batch_mediainfo()
    |> process_videos_with_mediainfo(video_infos)
  end

  defp fetch_batch_mediainfo(video_infos) do
    paths = Enum.map(video_infos, & &1.path)

    case execute_mediainfo_command(paths) do
      {:ok, mediainfo_map} ->
        {:ok, mediainfo_map}

      {:error, reason} ->
        Logger.warning(
          "Batch mediainfo fetch failed: #{reason}, falling back to individual processing"
        )

        {:error, :batch_fetch_failed}
    end
  end

  defp process_videos_with_mediainfo({:ok, mediainfo_map}, video_infos) do
    Logger.debug("Processing #{length(video_infos)} videos with batch-fetched mediainfo")

    video_infos
    |> Task.async_stream(
      &process_video_with_mediainfo(&1, Map.get(mediainfo_map, &1.path, :no_mediainfo)),
      max_concurrency: 5,
      timeout: :timer.minutes(5),
      on_timeout: :kill_task
    )
    |> handle_task_results()
  end

  defp process_videos_with_mediainfo({:error, :batch_fetch_failed}, video_infos) do
    Logger.debug("Processing #{length(video_infos)} videos individually")

    video_infos
    |> Task.async_stream(
      &process_video_individually/1,
      max_concurrency: 5,
      timeout: :timer.minutes(5),
      on_timeout: :kill_task
    )
    |> handle_task_results()
  end

  defp handle_task_results(stream) do
    results = Enum.to_list(stream)

    success_count = Enum.count(results, &match?({:ok, :ok}, &1))
    error_count = length(results) - success_count

    if error_count > 0 do
      Logger.warning(
        "Batch completed with #{error_count} errors out of #{length(results)} videos"
      )
    end

    :ok
  end

  defp process_video_with_mediainfo(video_info, mediainfo) do
    with {:ok, _eligibility} <- check_processing_eligibility(video_info),
         {:ok, validated_mediainfo} <- validate_mediainfo(mediainfo, video_info.path),
         {:ok, _video} <- upsert_video_record(video_info, validated_mediainfo) do
      Logger.debug("Successfully processed video: #{video_info.path}")
      :ok
    else
      {:skip, reason} ->
        Logger.debug("Skipping video #{video_info.path}: #{reason}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to process video #{video_info.path}: #{reason}")
        :error
    end
  rescue
    e ->
      Logger.error("Unexpected error processing #{video_info.path}: #{inspect(e)}")
      :error
  end

  defp process_video_individually(video_info) do
    with {:ok, _eligibility} <- check_processing_eligibility(video_info),
         {:ok, mediainfo} <- fetch_single_mediainfo(video_info.path),
         {:ok, validated_mediainfo} <- validate_mediainfo(mediainfo, video_info.path),
         {:ok, _video} <- upsert_video_record(video_info, validated_mediainfo) do
      Logger.debug("Successfully processed video: #{video_info.path}")
      Telemetry.emit_analyzer_throughput(1, 0)
      :ok
    else
      {:skip, reason} ->
        Logger.debug("Skipping video #{video_info.path}: #{reason}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to process video #{video_info.path}: #{reason}")
        :error
    end
  rescue
    e ->
      Logger.error("Unexpected error processing #{video_info.path}: #{inspect(e)}")
      :error
  end

  # Helper functions - ported from existing GenStage consumer

  defp check_processing_eligibility(%{path: path} = video_info) do
    video = Media.get_video_by_path(path) || :not_found
    force_reanalyze = Map.get(video_info, :force_reanalyze, false)

    if should_process_video?(video, force_reanalyze) do
      {:ok, true}
    else
      {:skip, "video already processed with valid bitrate"}
    end
  end

  defp should_process_video?(video, force_reanalyze) do
    video == :not_found or video.bitrate == 0 or force_reanalyze
  end

  defp validate_mediainfo(:no_mediainfo, path) do
    {:error, "no mediainfo found for #{path}"}
  end

  defp validate_mediainfo(mediainfo, path) do
    # Use existing CodecHelper for audio validation
    validate_audio_metadata(mediainfo, path)

    case extract_file_size(mediainfo) do
      {:ok, file_size} ->
        {:ok, Map.put(mediainfo, :size, file_size)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_file_size(mediainfo) do
    case Map.get(mediainfo, "FileSize") do
      size when is_integer(size) and size > 0 ->
        {:ok, size}

      size_str when is_binary(size_str) ->
        case Integer.parse(size_str) do
          {size, _} when size > 0 -> {:ok, size}
          _ -> {:error, "invalid file size format"}
        end

      _ ->
        {:error, "missing or invalid file size"}
    end
  end

  defp upsert_video_record(video_info, mediainfo) do
    %{path: path, service_id: service_id, service_type: service_type} = video_info
    file_size = Map.get(mediainfo, :size, 0)

    Media.upsert_video(%{
      path: path,
      mediainfo: mediainfo,
      service_id: service_id,
      service_type: service_type,
      size: file_size
    })
  end

  defp execute_mediainfo_command(paths) when is_list(paths) and paths != [] do
    case System.cmd("mediainfo", ["--Output=JSON" | paths]) do
      {json, 0} ->
        decode_and_parse_mediainfo_json(json)

      {error_msg, _code} ->
        {:error, "mediainfo command failed: #{error_msg}"}
    end
  end

  defp execute_mediainfo_command([]), do: {:ok, %{}}

  defp fetch_single_mediainfo(path) do
    case execute_mediainfo_command([path]) do
      {:ok, mediainfo_map} ->
        case Map.get(mediainfo_map, path) do
          :no_mediainfo -> {:error, "no mediainfo found for path"}
          mediainfo -> {:ok, mediainfo}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_and_parse_mediainfo_json(json) do
    case Jason.decode(json) do
      {:ok, %{"media" => media_list}} when is_list(media_list) ->
        parse_mediainfo_list(media_list)

      {:ok, data} ->
        {:error, "unexpected JSON structure: #{inspect(data)}"}

      {:error, reason} ->
        {:error, "JSON decode failed: #{inspect(reason)}"}
    end
  end

  defp parse_mediainfo_list(media_list) do
    Enum.reduce(media_list, {:ok, %{}}, fn media_item, {:ok, acc} ->
      case extract_complete_name(media_item) do
        {:ok, path} ->
          case parse_single_media_item(media_item) do
            {:ok, mediainfo} ->
              {:ok, Map.put(acc, path, mediainfo)}

            {:error, _reason} ->
              {:ok, Map.put(acc, path, :no_mediainfo)}
          end

        {:error, _reason} ->
          {:ok, acc}
      end
    end)
  end

  defp extract_complete_name(%{"track" => tracks}) when is_list(tracks) do
    case Enum.find(tracks, &(Map.get(&1, "@type") == "General")) do
      %{"CompleteName" => path} when is_binary(path) ->
        {:ok, path}

      _ ->
        {:error, "no complete name found"}
    end
  end

  defp extract_complete_name(_), do: {:error, "invalid media structure"}

  defp parse_single_media_item(%{"track" => tracks}) when is_list(tracks) do
    general = Enum.find(tracks, &(Map.get(&1, "@type") == "General"))
    video = Enum.find(tracks, &(Map.get(&1, "@type") == "Video"))
    audio = Enum.find(tracks, &(Map.get(&1, "@type") == "Audio"))

    case {general, video} do
      {%{} = g, %{} = v} ->
        mediainfo = %{
          "Duration" => extract_duration(g),
          "FileSize" => extract_file_size_from_track(g),
          "Width" => extract_numeric(v, "Width"),
          "Height" => extract_numeric(v, "Height"),
          "FrameRate" => extract_numeric(v, "FrameRate"),
          "BitRate" => extract_numeric(v, "BitRate"),
          "Format" => Map.get(v, "Format"),
          "CodecID" => Map.get(v, "CodecID")
        }

        mediainfo =
          if audio do
            Map.merge(mediainfo, %{
              "AudioFormat" => Map.get(audio, "Format"),
              "AudioCodecID" => Map.get(audio, "CodecID"),
              "AudioChannels" => extract_numeric(audio, "Channels"),
              "AudioSamplingRate" => extract_numeric(audio, "SamplingRate")
            })
          else
            mediainfo
          end

        {:ok, mediainfo}

      _ ->
        {:error, "missing required tracks"}
    end
  end

  defp parse_single_media_item(_), do: {:error, "invalid media item structure"}

  defp extract_duration(track) do
    case Map.get(track, "Duration") do
      duration when is_number(duration) -> trunc(duration)
      duration_str when is_binary(duration_str) ->
        case Float.parse(duration_str) do
          {duration, _} -> trunc(duration)
          _ -> 0
        end
      _ -> 0
    end
  end

  defp extract_file_size_from_track(track) do
    case Map.get(track, "FileSize") do
      size when is_integer(size) -> size
      size_str when is_binary(size_str) ->
        case Integer.parse(size_str) do
          {size, _} -> size
          _ -> 0
        end
      _ -> 0
    end
  end

  defp extract_numeric(track, key) do
    case Map.get(track, key) do
      value when is_number(value) -> value
      value_str when is_binary(value_str) ->
        case Float.parse(value_str) do
          {value, _} -> value
          _ -> 0
        end
      _ -> 0
    end
  end

  defp validate_audio_metadata(mediainfo, path) do
    codec = Map.get(mediainfo, "AudioCodecID", "")
    channels = Map.get(mediainfo, "AudioChannels", 0)

    case channels do
      ch when is_number(ch) and ch >= 1 and ch <= 32 ->
        :ok

      ch when is_number(ch) ->
        Logger.warning("Unusual channel count #{ch} for #{path}")

      _ ->
        Logger.warning("Invalid channel format '#{channels}' for #{path}")
    end

    if codec == "" do
      Logger.warning("Missing audio codec information for #{path}")
    end
  end
end
