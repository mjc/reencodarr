defmodule Reencodarr.Media.Debug do
  @moduledoc """
  Debug and diagnostic utilities for the Media context.

  Extracted from the main Media module to separate operational debugging
  tools from core business logic.
  """

  import Ecto.Query
  alias Reencodarr.Analyzer.QueueManager, as: AnalyzerQueueManager
  alias Reencodarr.Media.Clean
  alias Reencodarr.Media.{Library, Video, VideoQueries, Vmaf}
  alias Reencodarr.Repo

  require Logger

  @doc """
  Debug function to check the analyzer state and queue status.
  """
  @spec analyzer_status() :: map()
  def analyzer_status do
    %{
      analyzer_running: Reencodarr.Analyzer.Broadway.running?(),
      videos_needing_analysis: VideoQueries.videos_needing_analysis(5),
      manual_queue: get_manual_analyzer_queue(),
      total_analyzer_queue_count:
        length(VideoQueries.videos_needing_analysis(100)) +
          length(get_manual_analyzer_queue())
    }
  end

  @doc """
  Force trigger analysis of a specific video for debugging.
  """
  @spec force_analyze_video(String.t()) :: map() | {:error, String.t()}
  def force_analyze_video(video_path) do
    case Clean.get_video_by_path(video_path) do
      nil ->
        {:error, "Video not found at path: #{video_path}"}

      video ->
        # Delete all VMAFs and reset analysis fields to force re-analysis
        Reencodarr.Media.delete_vmafs_for_video(video.id)

        Reencodarr.Media.update_video(video, %{
          bitrate: nil,
          duration: nil,
          frame_rate: nil,
          video_codecs: nil,
          audio_codecs: nil,
          max_audio_channels: nil,
          resolution: nil,
          file_size: nil,
          failed: false
        })

        # Trigger Broadway dispatch
        result = Reencodarr.Analyzer.Broadway.dispatch_available()

        %{
          dispatch_result: result,
          broadway_running: Reencodarr.Analyzer.Broadway.running?()
        }
    end
  end

  @doc """
  Debug function to show how the encoding queue alternates between libraries.
  """
  @spec encoding_queue_by_library(integer()) :: [map()]
  def encoding_queue_by_library(limit \\ 10) do
    videos = VideoQueries.videos_ready_for_encoding(limit)

    videos
    |> Enum.with_index()
    |> Enum.map(fn {vmaf, index} ->
      %{
        position: index + 1,
        library_id: vmaf.video.library_id,
        video_path: vmaf.video.path,
        percent: vmaf.percent,
        savings: vmaf.savings
      }
    end)
  end

  @doc """
  Explains where a specific video path is located in the system and which queues it belongs to.

  Returns a detailed map with information about:
  - Database state (analyzed, has VMAF, ready for encoding, etc.)
  - Current queue memberships (analyzer, CRF searcher, encoder)
  - Processing status and next steps
  - Error states if any

  ## Examples

      iex> Reencodarr.Media.Debug.explain_path_location("/path/to/video.mkv")
      %{
        path: "/path/to/video.mkv",
        exists_in_db: true,
        database_state: %{
          analyzed: true,
          has_vmaf: true,
          ready_for_encoding: true,
          reencoded: false,
          failed: false
        },
        queue_memberships: %{
          analyzer_broadway: false,
          analyzer_manual: false,
          crf_searcher_broadway: false,
          crf_searcher_genserver: false,
          encoder_broadway: true,
          encoder_genserver: false
        },
        next_steps: ["ready for encoding"],
        details: %{
          video_id: 123,
          library_name: "Movies",
          bitrate: 5000,
          vmaf_count: 3,
          chosen_vmaf: %{crf: 23, percent: 95.2}
        }
      }
  """
  @spec explain_path_location(String.t()) :: map()
  def explain_path_location(path) when is_binary(path) do
    case Clean.get_video_by_path(path) do
      nil ->
        %{
          path: path,
          exists_in_db: false,
          database_state: %{
            analyzed: false,
            has_vmaf: false,
            ready_for_encoding: false,
            reencoded: false,
            failed: false
          },
          queue_memberships: %{
            analyzer_broadway: false,
            analyzer_manual: false,
            crf_searcher_broadway: false,
            crf_searcher_genserver: false,
            encoder_broadway: false,
            encoder_genserver: false
          },
          next_steps: ["not in database - needs to be added"],
          details: nil
        }

      video ->
        # Get associated VMAFs
        vmafs = Repo.all(from v in Vmaf, where: v.video_id == ^video.id, preload: [:video])
        chosen_vmaf = Enum.find(vmafs, & &1.chosen)

        # Determine database state
        analyzed = !is_nil(video.bitrate)
        has_vmaf = length(vmafs) > 0
        ready_for_encoding = !is_nil(chosen_vmaf) && !video.reencoded && !video.failed

        # Check queue memberships
        queue_memberships = %{
          analyzer_broadway: path_in_analyzer_broadway?(path),
          analyzer_manual: path_in_analyzer_manual?(path),
          crf_searcher_broadway: path_in_crf_searcher_broadway?(path),
          crf_searcher_genserver: path_in_crf_searcher_genserver?(path),
          encoder_broadway: path_in_encoder_broadway?(path),
          encoder_genserver: path_in_encoder_genserver?(path)
        }

        # Determine next steps
        next_steps =
          determine_next_steps(video, analyzed, has_vmaf, ready_for_encoding, chosen_vmaf)

        # Get library name
        library = video.library_id && Repo.get(Library, video.library_id)

        %{
          path: path,
          exists_in_db: true,
          database_state: %{
            analyzed: analyzed,
            has_vmaf: has_vmaf,
            ready_for_encoding: ready_for_encoding,
            reencoded: video.reencoded,
            failed: video.failed
          },
          queue_memberships: queue_memberships,
          next_steps: next_steps,
          details: %{
            video_id: video.id,
            library_name: library && library.name,
            bitrate: video.bitrate,
            vmaf_count: length(vmafs),
            chosen_vmaf: chosen_vmaf && %{crf: chosen_vmaf.crf, percent: chosen_vmaf.percent},
            video_codecs: video.video_codecs,
            audio_codecs: video.audio_codecs,
            size: video.size,
            inserted_at: video.inserted_at,
            updated_at: video.updated_at
          }
        }
    end
  end

  @doc """
  Diagnostic function to test inserting a video path and report exactly what happened.

  This function attempts to create or upsert a video with minimal required data and
  provides detailed feedback about the operation including any validation errors,
  constraint violations, or success messages.

  ## Examples

      iex> Reencodarr.Media.Debug.test_insert_path("/path/to/test/video.mkv")
      %{
        success: true,
        operation: "insert",
        video_id: 123,
        messages: ["Successfully inserted new video"],
        path: "/path/to/test/video.mkv",
        library_id: 1,
        errors: []
      }
  """
  @spec test_insert_path(String.t(), map()) :: map()
  def test_insert_path(path, additional_attrs \\ %{}) when is_binary(path) do
    Logger.info("🧪 Testing path insertion: #{path}")

    # Gather initial diagnostics
    diagnostics = gather_path_diagnostics(path, additional_attrs)

    # Attempt the upsert operation
    result = attempt_video_upsert(diagnostics)

    # Build final result with all diagnostics
    build_final_result(result, diagnostics)
  end

  # === Private Helper Functions ===

  # Helper functions to check queue memberships
  defp path_in_analyzer_broadway?(_path) do
    # The analyzer Broadway producer manages its own queue internally
    # We can't easily check this without accessing its internal state
    # For now, return false as this would require more complex introspection
    false
  end

  defp path_in_analyzer_manual?(path) do
    # Check the manual queue through proper API boundary
    manual_queue = get_manual_analyzer_queue()

    Enum.any?(manual_queue, fn item ->
      case item do
        %{path: item_path} -> String.downcase(item_path) == String.downcase(path)
        _ -> false
      end
    end)
  end

  # Get manual analyzer queue through proper boundaries
  defp get_manual_analyzer_queue do
    # Use the Analyzer context's public API instead of directly accessing QueueManager
    case GenServer.whereis(AnalyzerQueueManager) do
      nil ->
        []

      _pid ->
        try do
          GenServer.call(AnalyzerQueueManager, :get_queue, 1000)
        catch
          :exit, _ -> []
        end
    end
  end

  defp path_in_crf_searcher_broadway?(_path), do: false
  defp path_in_crf_searcher_genserver?(_path), do: false
  defp path_in_encoder_broadway?(_path), do: false
  defp path_in_encoder_genserver?(_path), do: false

  defp determine_next_steps(video, analyzed, has_vmaf, ready_for_encoding, chosen_vmaf) do
    determine_video_status(video, analyzed, has_vmaf, ready_for_encoding, chosen_vmaf)
  end

  defp determine_video_status(video, _analyzed, _has_vmaf, _ready_for_encoding, _chosen_vmaf)
       when video.failed do
    ["marked as failed - manual intervention needed"]
  end

  defp determine_video_status(video, _analyzed, _has_vmaf, _ready_for_encoding, _chosen_vmaf)
       when video.reencoded do
    ["already reencoded - processing complete"]
  end

  defp determine_video_status(_video, _analyzed, _has_vmaf, true, chosen_vmaf) do
    ["ready for encoding with CRF #{chosen_vmaf.crf}"]
  end

  defp determine_video_status(_video, _analyzed, true, _ready_for_encoding, nil) do
    ["has VMAF results but none chosen - needs manual selection"]
  end

  defp determine_video_status(video, true, false, _ready_for_encoding, _chosen_vmaf) do
    determine_analyzed_video_steps(video)
  end

  defp determine_video_status(_video, false, _has_vmaf, _ready_for_encoding, _chosen_vmaf) do
    ["needs analysis - should be in analyzer queue"]
  end

  defp determine_video_status(_video, _analyzed, _has_vmaf, _ready_for_encoding, _chosen_vmaf) do
    ["unknown state - check manually"]
  end

  defp determine_analyzed_video_steps(video) do
    cond do
      has_av1_codec?(video) ->
        ["already AV1 encoded - no CRF search needed"]

      has_opus_codec?(video) ->
        ["has Opus audio - skipped from CRF search queue"]

      true ->
        ["analyzed but needs CRF search"]
    end
  end

  defp has_av1_codec?(video) do
    Enum.any?(video.video_codecs || [], fn codec ->
      String.downcase(codec) |> String.contains?("av1")
    end)
  end

  defp has_opus_codec?(video) do
    Enum.any?(video.audio_codecs || [], fn codec ->
      String.downcase(codec) |> String.contains?("opus")
    end)
  end

  defp gather_path_diagnostics(path, additional_attrs) do
    file_exists = File.exists?(path)
    existing_video = Clean.get_video_by_path(path)

    # Find library for this path - same logic as in VideoUpsert
    library_id =
      Repo.one(
        from l in Library,
          where: fragment("? LIKE CONCAT(?, '%')", ^path, l.path),
          order_by: [desc: fragment("LENGTH(?)", l.path)],
          limit: 1,
          select: l.id
      )

    attrs = build_base_attrs(path, library_id) |> Map.merge(additional_attrs)

    {messages, errors} = build_diagnostic_messages(file_exists, existing_video, library_id, path)

    %{
      path: path,
      file_exists: file_exists,
      existing_video: existing_video,
      library_id: library_id,
      attrs: attrs,
      messages: messages,
      errors: errors
    }
  end

  defp build_base_attrs(path, library_id) do
    %{
      "path" => path,
      "library_id" => library_id,
      "service_type" => "sonarr",
      "service_id" => "test_#{System.system_time(:second)}",
      "size" => 1_000_000,
      "duration" => 3600.0,
      "video_codecs" => ["H.264"],
      "audio_codecs" => ["AAC"],
      "reencoded" => false,
      "failed" => false
    }
  end

  defp build_diagnostic_messages(file_exists, existing_video, library_id, path) do
    messages = []
    errors = []

    {messages, errors} = add_file_existence_messages(file_exists, path, messages, errors)
    messages = add_existing_video_messages(existing_video, messages)
    {messages, errors} = add_library_messages(library_id, path, messages, errors)

    {messages, errors}
  end

  defp add_file_existence_messages(file_exists, path, messages, errors) do
    if file_exists do
      {["File exists on filesystem" | messages], errors}
    else
      {["File does not exist on filesystem" | messages],
       ["File does not exist on filesystem: #{path}" | errors]}
    end
  end

  defp add_existing_video_messages(existing_video, messages) do
    case existing_video do
      nil -> ["No existing video found in database" | messages]
      %Video{id: id} -> ["Found existing video with ID: #{id}" | messages]
    end
  end

  defp add_library_messages(library_id, _path, messages, errors) do
    case library_id do
      nil ->
        {["No matching library found for path" | messages],
         ["No matching library found for path" | errors]}

      lib_id ->
        {["Found library ID: #{lib_id}" | messages], errors}
    end
  end

  defp attempt_video_upsert(diagnostics) do
    case Clean.upsert_video(diagnostics.attrs) do
      {:ok, video} ->
        operation = if diagnostics.existing_video, do: "upsert", else: "insert"

        %{
          success: true,
          operation: operation,
          video_id: video.id,
          messages: [
            "Successfully #{operation}ed video with ID: #{video.id}" | diagnostics.messages
          ],
          errors: diagnostics.errors
        }

      {:error, %Ecto.Changeset{} = changeset} ->
        changeset_errors =
          changeset.errors
          |> Enum.map(fn {field, {message, _}} -> "#{field}: #{message}" end)

        %{
          success: false,
          operation: "failed",
          video_id: nil,
          messages: ["Changeset validation failed" | diagnostics.messages],
          errors: changeset_errors ++ diagnostics.errors
        }

      {:error, reason} ->
        %{
          success: false,
          operation: "failed",
          video_id: nil,
          messages: ["Operation failed with error" | diagnostics.messages],
          errors: ["Error: #{inspect(reason)}" | diagnostics.errors]
        }
    end
  end

  defp build_final_result(result, diagnostics) do
    final_result =
      result
      |> Map.put(:path, diagnostics.path)
      |> Map.put(:library_id, diagnostics.library_id)
      |> Map.put(:file_exists, diagnostics.file_exists)
      |> Map.put(:had_existing_video, !is_nil(diagnostics.existing_video))
      |> Map.put(:messages, Enum.reverse(result.messages))
      |> Map.put(:errors, Enum.reverse(result.errors))

    Logger.info("🧪 Test result: #{if result.success, do: "SUCCESS", else: "FAILED"}")

    if result.success do
      Logger.info("   Video ID: #{result.video_id}, Operation: #{result.operation}")
    else
      Logger.warning("   Errors: #{Enum.join(result.errors, ", ")}")
    end

    final_result
  end
end
