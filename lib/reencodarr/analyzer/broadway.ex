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
    Reencodarr.Analyzer.Broadway.Producer.add_video(video_info)
  end

  @doc """
  Check if the analyzer is running (not paused).
  """
  def running? do
    case Process.whereis(__MODULE__) do
      nil -> false
      _pid -> Reencodarr.Analyzer.Broadway.Producer.running?()
    end
  end

  @doc """
  Pause the analyzer.
  """
  def pause do
    Reencodarr.Analyzer.Broadway.Producer.pause()
  end

  @doc """
  Resume the analyzer.
  """
  def resume do
    Reencodarr.Analyzer.Broadway.Producer.resume()
  end

  # Alias for API compatibility
  def start, do: resume()

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
    video_infos = Enum.map(messages, & &1.data)

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

  defp process_video_with_mediainfo(video_info, :no_mediainfo) do
    Logger.warning("No mediainfo available for #{video_info.path}, processing individually")
    process_video_individually(video_info)
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
      Logger.error("Stacktrace: #{inspect(__STACKTRACE__)}")
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
    video = Media.get_video_by_path(path)
    force_reanalyze = Map.get(video_info, :force_reanalyze, false)

    if should_process_video?(video, force_reanalyze) do
      {:ok, true}
    else
      {:skip, "video already processed with valid bitrate"}
    end
  end

  defp should_process_video?(nil, _force_reanalyze), do: true

  defp should_process_video?(video, force_reanalyze) do
    video.bitrate == 0 or force_reanalyze
  end

  defp validate_mediainfo(:no_mediainfo, path) do
    {:error, "no mediainfo found for #{path}"}
  end

  defp validate_mediainfo(nil, path) do
    {:error, "nil mediainfo received for #{path}"}
  end

  defp validate_mediainfo(mediainfo, path) when is_map(mediainfo) do
    # Log structure for debugging
    Logger.debug("Validating mediainfo for #{path}")

    # Check for common structure patterns
    if Map.has_key?(mediainfo, "media") do
      Logger.debug("Standard mediainfo structure with 'media' key detected")
    else
      Logger.debug(
        "Non-standard mediainfo structure detected (no 'media' key), will be handled by conversion logic"
      )
    end

    # Try different ways to extract file size
    case extract_file_size(mediainfo) do
      {:ok, file_size} ->
        # Add file size to mediainfo for later use
        {:ok, Map.put(mediainfo, :size, file_size)}

      {:error, reason} ->
        # Log issue but try to proceed anyway with a default size
        Logger.warning("Could not extract file size for #{path}: #{reason}")
        # Use stat command to get file size as fallback
        case get_file_size_from_path(path) do
          {:ok, fallback_size} ->
            Logger.info("Using fallback file size of #{fallback_size} for #{path}")
            {:ok, Map.put(mediainfo, :size, fallback_size)}

          {:error, _} ->
            # If all attempts fail, use a default size and warn
            Logger.warning("Using default file size for #{path}")
            {:ok, Map.put(mediainfo, :size, 0)}
        end
    end
  end

  # Add a catch-all clause for validate_mediainfo
  defp validate_mediainfo(invalid_mediainfo, path) do
    Logger.error("Invalid mediainfo format for #{path}: #{inspect(invalid_mediainfo)}")
    {:error, "invalid mediainfo format"}
  end

  # Fallback to get file size using the file system
  defp get_file_size_from_path(path) do
    try do
      case File.stat(path) do
        {:ok, %{size: size}} ->
          {:ok, size}

        {:error, reason} ->
          Logger.warning("File stat failed for #{path}: #{reason}")
          {:error, reason}
      end
    rescue
      e ->
        Logger.warning("Exception getting file size for #{path}: #{inspect(e)}")
        {:error, :exception}
    end
  end

  defp extract_file_size(mediainfo) do
    # Try multiple possible locations for file size in different MediaInfo structures
    cond do
      # Check direct FileSize key (common in flat structures)
      size = get_size_if_valid(Map.get(mediainfo, "FileSize")) ->
        {:ok, size}

      # Check in media.track structure - General track
      media = Map.get(mediainfo, "media") ->
        track = get_in(media, ["track"])

        cond do
          # If track is a list, look for General track
          is_list(track) ->
            general_track = Enum.find(track, &(&1["@type"] == "General"))

            if general_track do
              if size = get_size_if_valid(Map.get(general_track, "FileSize")) do
                {:ok, size}
              else
                {:error, "no valid file size in general track"}
              end
            else
              {:error, "no general track found"}
            end

          # If track is a map and it's the General track
          is_map(track) and Map.get(track, "@type") == "General" ->
            if size = get_size_if_valid(Map.get(track, "FileSize")) do
              {:ok, size}
            else
              {:error, "no valid file size in general track"}
            end

          # Otherwise no valid size found
          true ->
            {:error, "could not find file size in mediainfo structure"}
        end

      # No known structure found
      true ->
        {:error, "missing or invalid file size, unknown mediainfo structure"}
    end
  end

  # Helper to validate and convert size values
  defp get_size_if_valid(size) do
    cond do
      is_integer(size) and size > 0 ->
        size

      is_binary(size) ->
        case Integer.parse(size) do
          {parsed_size, _} when parsed_size > 0 -> parsed_size
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp upsert_video_record(video_info, mediainfo) do
    %{path: path, service_id: service_id, service_type: service_type} = video_info
    file_size = Map.get(mediainfo, :size, 0)

    case Media.upsert_video(%{
           path: path,
           mediainfo: mediainfo,
           service_id: service_id,
           service_type: service_type,
           size: file_size
         }) do
      {:ok, video} ->
        {:ok, video}

      {:error, %Ecto.Changeset{} = changeset} ->
        errors = format_changeset_errors(changeset)
        Logger.error("Failed to upsert video record for #{path}: #{errors}")
        {:error, "validation failed: #{errors}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_changeset_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end)
    |> Enum.join("; ")
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
    Logger.debug("Decoding mediainfo JSON")

    json_trimmed = String.slice(json, 0, 1000)
    Logger.debug("JSON sample: #{json_trimmed}...")

    try do
      case Jason.decode(json) do
        {:ok, [%{"media" => _} | _] = media_info_list} when is_list(media_info_list) ->
          Logger.debug("Parsing mediainfo from list of media objects")
          media_list = Enum.map(media_info_list, & &1["media"])
          parse_mediainfo_list(media_list)

        {:ok, %{"media" => media_item}} when is_map(media_item) ->
          Logger.debug("Parsing mediainfo from single media object")
          parse_mediainfo_list([media_item])

        {:ok, %{"media" => media_list}} when is_list(media_list) ->
          Logger.debug("Parsing mediainfo from media list")
          parse_mediainfo_list(media_list)

        # Handle flat MediaInfo structure (no "media" key)
        {:ok, data} when is_map(data) ->
          # Check if this looks like a flat structure
          if Map.has_key?(data, "track") or
               (Map.has_key?(data, "FileSize") and Map.has_key?(data, "Duration")) or
               Map.has_key?(data, "Width") or Map.has_key?(data, "Height") or
               Map.has_key?(data, "Format") do
            Logger.debug("Detected flat MediaInfo structure, wrapping in proper format")
            # Wrap in the expected structure
            wrapped_data = %{"media" => data}
            # Try to extract path
            path =
              case data do
                %{"@ref" => path} when is_binary(path) -> path
                %{"CompleteName" => path} when is_binary(path) -> path
                _ -> nil
              end

            if path do
              # Create a map with the path as key
              {:ok, %{path => wrapped_data}}
            else
              Logger.warning(
                "Flat MediaInfo structure detected but no path found: #{inspect(data, pretty: true, limit: 5000)}"
              )

              {:error, "no path in flat mediainfo structure"}
            end
          else
            Logger.error(
              "Unexpected JSON structure from mediainfo: #{inspect(data, pretty: true, limit: 5000)}"
            )

            {:error, "unexpected JSON structure"}
          end

        {:ok, data} ->
          Logger.error(
            "Unexpected JSON structure from mediainfo: #{inspect(data, pretty: true, limit: 5000)}"
          )

          {:error, "unexpected JSON structure"}

        {:error, reason} ->
          Logger.error("JSON decode failed: #{inspect(reason)}")
          {:error, "JSON decode failed: #{inspect(reason)}"}
      end
    rescue
      e ->
        Logger.error("Error parsing mediainfo JSON: #{inspect(e)}")
        Logger.error("Stacktrace: #{inspect(__STACKTRACE__)}")
        {:error, "error parsing JSON: #{inspect(e)}"}
    end
  end

  defp parse_mediainfo_list(media_list) do
    Enum.reduce(media_list, {:ok, %{}}, fn media_item, {:ok, acc} ->
      Logger.debug("Parsing media item: #{inspect(media_item)}")

      case extract_complete_name(media_item) do
        {:ok, path} ->
          Logger.debug("Extracted path: #{path}")

          case parse_single_media_item(media_item) do
            {:ok, mediainfo} ->
              {:ok, Map.put(acc, path, mediainfo)}

            {:error, reason} ->
              Logger.warning("Failed to parse single media item for #{path}: #{reason}")
              {:ok, Map.put(acc, path, :no_mediainfo)}
          end

        {:error, reason} ->
          Logger.warning("Failed to extract complete name: #{reason}")
          {:ok, acc}
      end
    end)
  end

  defp extract_complete_name(%{"@ref" => path}) when is_binary(path), do: {:ok, path}

  defp extract_complete_name(%{"track" => tracks}) when is_list(tracks) do
    case Enum.find(tracks, &(Map.get(&1, "@type") == "General")) do
      %{"CompleteName" => path} when is_binary(path) ->
        {:ok, path}

      _ ->
        {:error, "no complete name found"}
    end
  end

  defp extract_complete_name(media_item) do
    Logger.debug("Attempting to extract complete name from: #{inspect(media_item)}")
    {:error, "invalid media structure"}
  end

  defp parse_single_media_item(%{"track" => tracks}) when is_list(tracks) do
    # Return the original nested structure that downstream code expects
    # The structure should be %{"media" => %{"track" => tracks}}
    {:ok, %{"media" => %{"track" => tracks}}}
  end

  defp parse_single_media_item(_), do: {:error, "invalid media item structure"}
end
