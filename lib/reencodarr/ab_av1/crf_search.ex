defmodule Reencodarr.AbAv1.CrfSearch do
  @moduledoc """
  GenServer for handling CRF search operations using ab-av1.

  This module manages the CRF search process for videos to find optimal
  encoding parameters based on VMAF quality targets.
  """

  use GenServer

  alias Reencodarr.AbAv1.Helper
  alias Reencodarr.AbAv1.OutputParser
  alias Reencodarr.Core.Time
  alias Reencodarr.CrfSearcher.Broadway.Producer
  alias Reencodarr.DataConverters
  alias Reencodarr.ErrorHelpers
  alias Reencodarr.Formatters
  alias Reencodarr.{Media, Repo, Telemetry}
  alias Reencodarr.Statistics.CrfSearchProgress

  require Logger

  # Constants
  # 10GB
  @max_file_size_bytes 10 * 1024 * 1024 * 1024
  # Default VMAF quality target
  @default_vmaf_target 95

  # Public API
  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec crf_search(Media.Video.t(), integer()) :: :ok
  def crf_search(%Media.Video{state: :encoded, path: path, id: video_id}, _vmaf_percent) do
    Logger.info("Skipping crf search for video #{path} as it is already encoded")
    broadcast_crf_search_completion(video_id, :skipped)
    :ok
  end

  def crf_search(%Media.Video{} = video, vmaf_percent) do
    if Media.chosen_vmaf_exists?(video) do
      Logger.info("Skipping crf search for video #{video.path} as a chosen VMAF already exists")

      # Publish skipped event to PubSub
      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        "crf_search_events",
        {:crf_search_completed, video.id, :skipped}
      )
    else
      GenServer.cast(__MODULE__, {:crf_search, video, vmaf_percent})
    end

    :ok
  end

  def running? do
    case GenServer.whereis(__MODULE__) do
      nil ->
        false

      _pid ->
        try do
          GenServer.call(__MODULE__, :running?) == :running
        catch
          :exit, _ -> false
        end
    end
  end

  # Test helpers - only available in test environment
  if Mix.env() == :test do
    def has_preset_6_params?(params), do: has_preset_6_params_private(params)
    def should_retry_with_preset_6(video_id), do: should_retry_with_preset_6_private(video_id)

    def clear_vmaf_records_for_video(video_id, vmaf_records),
      do: clear_vmaf_records_for_video_private(video_id, vmaf_records)

    def build_crf_search_args_with_preset_6(video, vmaf_percent),
      do: build_crf_search_args_with_preset_6_private(video, vmaf_percent)

    # Legacy test function names for backward compatibility
    def should_retry_with_preset_6_for_test(video_id), do: should_retry_with_preset_6(video_id)

    def build_crf_search_args_with_preset_6_for_test(video, vmaf_percent),
      do: build_crf_search_args_with_preset_6(video, vmaf_percent)

    def build_crf_search_args_for_test(video, vmaf_percent),
      do: build_crf_search_args(video, vmaf_percent)

    # Private helper functions for tests
    defp has_preset_6_params_private(params) when is_list(params) do
      # Check for adjacent --preset and 6 in a flat list
      case check_for_preset_6_in_flat_list(params) do
        true ->
          true

        false ->
          # Also check for tuple format
          Enum.any?(params, fn
            {flag, value} -> flag == "--preset" and value == "6"
            _ -> false
          end)
      end
    end

    defp has_preset_6_params_private(_), do: false

    # Helper to check for --preset 6 in flat list format
    defp check_for_preset_6_in_flat_list([]), do: false
    defp check_for_preset_6_in_flat_list([_]), do: false
    defp check_for_preset_6_in_flat_list(["--preset", "6" | _]), do: true
    defp check_for_preset_6_in_flat_list([_ | rest]), do: check_for_preset_6_in_flat_list(rest)
  end

  # GenServer callbacks
  # === GenServer Callbacks ===

  @impl true
  def init(:ok) do
    {:ok, %{port: :none, current_task: :none, partial_line_buffer: "", output_buffer: []}}
  end

  @impl true
  def handle_cast({:crf_search, video, vmaf_percent}, %{port: :none} = state) do
    args = build_crf_search_args(video, vmaf_percent)

    new_state = %{
      state
      | port: Helper.open_port(args),
        current_task: %{video: video, args: args, target_vmaf: vmaf_percent},
        output_buffer: []
    }

    # Emit telemetry event for CRF search start
    Telemetry.emit_crf_search_started()

    {:noreply, new_state}
  end

  def handle_cast({:crf_search_with_preset_6, video, vmaf_percent}, %{port: :none} = state) do
    Logger.info("CrfSearch: Starting retry with --preset 6 for video #{video.id}")
    args = build_crf_search_args_with_preset_6_private(video, vmaf_percent)

    new_state = %{
      state
      | port: Helper.open_port(args),
        current_task: %{video: video, args: args, target_vmaf: vmaf_percent},
        output_buffer: []
    }

    # Emit telemetry event for CRF search start
    Telemetry.emit_crf_search_started()

    {:noreply, new_state}
  end

  def handle_cast({:crf_search_with_preset_6, video, _vmaf_percent}, state) do
    Logger.error(
      "CRF search already in progress, cannot retry with preset 6 for video #{video.id}"
    )

    # Publish a skipped event since this request was rejected
    Phoenix.PubSub.broadcast(
      Reencodarr.PubSub,
      "crf_search_events",
      {:crf_search_completed, video.id, :skipped}
    )

    {:noreply, state}
  end

  def handle_cast({:crf_search, video, _vmaf_percent}, state) do
    Logger.error("CRF search already in progress for video #{video.id}")

    # Publish a skipped event since this request was rejected
    Phoenix.PubSub.broadcast(
      Reencodarr.PubSub,
      "crf_search_events",
      {:crf_search_completed, video.id, :skipped}
    )

    {:noreply, state}
  end

  @impl true
  def handle_info(:test_reset, state) do
    # Test-only handler to force reset the GenServer state
    # This ensures clean state between tests
    if Mix.env() == :test do
      # Close any open port
      if state.port != :none do
        try do
          Port.close(state.port)
        rescue
          _ -> :ok
        end
      end

      # Reset to initial state
      {:noreply, %{port: :none, current_task: :none, partial_line_buffer: "", output_buffer: []}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        {port, {:data, {:eol, line}}},
        %{
          port: port,
          current_task: %{video: video, args: args, target_vmaf: target_vmaf},
          partial_line_buffer: buffer,
          output_buffer: output_buffer
        } =
          state
      ) do
    full_line = buffer <> line
    process_line(full_line, video, args, target_vmaf)

    # Add the line to our output buffer for failure tracking
    new_output_buffer = [full_line | output_buffer]

    {:noreply, %{state | partial_line_buffer: "", output_buffer: new_output_buffer}}
  end

  @impl true
  def handle_info(
        {port, {:data, {:noeol, data}}},
        %{port: port, current_task: %{video: video}, partial_line_buffer: buffer} = state
      ) do
    Logger.debug("Received partial data chunk for video #{video.id}, buffering.")
    new_buffer = buffer <> data
    {:noreply, %{state | partial_line_buffer: new_buffer}}
  end

  @impl true
  def handle_info({port, {:exit_status, 0}}, %{port: port, current_task: %{video: video}} = state) do
    Logger.info("✅ AbAv1: CRF search completed for video #{video.id} (#{video.title})")

    # CRITICAL: Update video state to crf_searched to prevent infinite loop
    ErrorHelpers.handle_error_with_default(
      Reencodarr.Media.update_video_status(video, %{"state" => "crf_searched"}),
      :ok,
      "Failed to update video #{video.id} state"
    )

    # Publish completion event to PubSub
    Phoenix.PubSub.broadcast(
      Reencodarr.PubSub,
      "crf_search_events",
      {:crf_search_completed, video.id, :success}
    )

    # Check for pending preset 6 retry
    case Process.get(:pending_preset_6_retry) do
      {retry_video, retry_target_vmaf} ->
        Process.delete(:pending_preset_6_retry)
        {cleanup_reply, cleanup_state} = perform_crf_search_cleanup(state)

        {cleanup_reply, cleanup_state,
         {:continue, {:preset_6_retry, retry_video, retry_target_vmaf}}}

      nil ->
        perform_crf_search_cleanup(state)
    end
  end

  @impl true
  def handle_info(
        {port, {:exit_status, exit_code}},
        %{
          port: port,
          current_task: %{video: video, args: args, target_vmaf: target_vmaf},
          output_buffer: output_buffer
        } = state
      )
      when exit_code != 0 do
    Logger.error("CRF search failed for video #{video.id} with exit code #{exit_code}")

    # Capture the full command output for failure analysis
    full_output = output_buffer |> Enum.reverse() |> Enum.join("\n")
    command_line = "ab-av1 " <> Enum.join(args, " ")

    handle_crf_search_failure(video, target_vmaf, exit_code, command_line, full_output, state)
  end

  @impl true
  def handle_info({:scanning_update, status, data}, state) do
    case status do
      :progress ->
        Logger.debug("Received vmaf search progress")
        Media.upsert_vmaf(data)

      :finished ->
        Media.upsert_vmaf(data)

      :failed ->
        Logger.error("Scanning failed: #{data}")
    end

    {:noreply, state}
  end

  defp handle_crf_search_failure(video, target_vmaf, exit_code, command_line, full_output, state) do
    # Check if we should retry with --preset 6 on process failure as well
    case should_retry_with_preset_6_private(video.id) do
      {:retry, existing_vmafs} ->
        handle_retry_with_preset_6(
          video,
          target_vmaf,
          exit_code,
          command_line,
          full_output,
          existing_vmafs,
          state
        )

      :already_retried ->
        handle_already_retried_failure(
          video,
          target_vmaf,
          exit_code,
          command_line,
          full_output,
          state
        )

      :mark_failed ->
        handle_mark_failed(video, target_vmaf, exit_code, command_line, full_output, state)
    end
  end

  defp handle_retry_with_preset_6(
         video,
         target_vmaf,
         exit_code,
         command_line,
         full_output,
         existing_vmafs,
         state
       ) do
    Logger.info(
      "CrfSearch: Retrying video #{video.id} (#{Path.basename(video.path)}) with --preset 6 after process failure (exit code #{exit_code})"
    )

    # Record the process failure with full output before retrying
    Reencodarr.FailureTracker.record_vmaf_calculation_failure(
      video,
      "Process failed with exit code #{exit_code}",
      context: %{
        exit_code: exit_code,
        command: command_line,
        full_output: full_output,
        will_retry: true,
        target_vmaf: target_vmaf
      }
    )

    # Clear existing VMAF records for this video to start fresh
    clear_vmaf_records_for_video_private(video.id, existing_vmafs)

    # Reset video state to analyzed for retry with preset 6
    ErrorHelpers.handle_error_with_default(
      Reencodarr.Media.update_video_status(video, %{"state" => "analyzed"}),
      :ok,
      "Failed to reset video #{video.id} state for retry"
    )

    # Publish failure event first
    Phoenix.PubSub.broadcast(
      Reencodarr.PubSub,
      "crf_search_events",
      {:crf_search_completed, video.id, {:error, exit_code}}
    )

    # Clean up current state
    {_reply, cleanup_state} = perform_crf_search_cleanup(state)

    # Requeue the video with --preset 6 parameter
    GenServer.cast(__MODULE__, {:crf_search_with_preset_6, video, target_vmaf})

    {:noreply, cleanup_state}
  end

  defp handle_already_retried_failure(
         video,
         target_vmaf,
         exit_code,
         command_line,
         full_output,
         state
       ) do
    Logger.error(
      "CrfSearch: Video #{video.id} (#{Path.basename(video.path)}) already retried with --preset 6, marking as failed"
    )

    # Record the final failure with full output
    Reencodarr.FailureTracker.record_preset_retry_failure(video, 6, 1,
      context: %{
        exit_code: exit_code,
        command: command_line,
        full_output: full_output,
        target_vmaf: target_vmaf,
        final_failure: true
      }
    )

    # Publish completion event to PubSub
    Phoenix.PubSub.broadcast(
      Reencodarr.PubSub,
      "crf_search_events",
      {:crf_search_completed, video.id, {:error, exit_code}}
    )

    Media.mark_as_failed(video)

    # Check for pending preset 6 retry even in failure cases
    case Process.get(:pending_preset_6_retry) do
      {retry_video, retry_target_vmaf} ->
        Process.delete(:pending_preset_6_retry)
        {cleanup_reply, cleanup_state} = perform_crf_search_cleanup(state)

        {cleanup_reply, cleanup_state,
         {:continue, {:preset_6_retry, retry_video, retry_target_vmaf}}}

      nil ->
        perform_crf_search_cleanup(state)
    end
  end

  defp handle_mark_failed(video, target_vmaf, exit_code, command_line, full_output, state) do
    # Record the process failure with full output
    Reencodarr.FailureTracker.record_vmaf_calculation_failure(
      video,
      "Process failed with exit code #{exit_code}",
      context: %{
        exit_code: exit_code,
        command: command_line,
        full_output: full_output,
        target_vmaf: target_vmaf,
        final_failure: true
      }
    )

    # Publish completion event to PubSub
    Phoenix.PubSub.broadcast(
      Reencodarr.PubSub,
      "crf_search_events",
      {:crf_search_completed, video.id, {:error, exit_code}}
    )

    Media.mark_as_failed(video)

    # Check for pending preset 6 retry even in failure cases
    case Process.get(:pending_preset_6_retry) do
      {retry_video, retry_target_vmaf} ->
        Process.delete(:pending_preset_6_retry)
        {cleanup_reply, cleanup_state} = perform_crf_search_cleanup(state)

        {cleanup_reply, cleanup_state,
         {:continue, {:preset_6_retry, retry_video, retry_target_vmaf}}}

      nil ->
        perform_crf_search_cleanup(state)
    end
  end

  @impl true
  def handle_continue({:preset_6_retry, video, target_vmaf}, state) do
    Logger.debug("CrfSearch: Executing preset 6 retry for video #{video.id} via handle_continue")
    GenServer.cast(__MODULE__, {:crf_search_with_preset_6, video, target_vmaf})
    {:noreply, state}
  end

  @impl true
  def handle_call(:running?, _from, %{port: port} = state) do
    status = if port == :none, do: :not_running, else: :running
    {:reply, status, state}
  end

  # Private helper functions
  defp perform_crf_search_cleanup(state) do
    # Emit telemetry event for CRF search completion
    Telemetry.emit_crf_search_completed()

    # Notify the Broadway producer that CRF search is now available
    Producer.dispatch_available()

    new_state = %{state | port: :none, current_task: :none, partial_line_buffer: ""}
    {:noreply, new_state}
  end

  def process_line(line, video, args, target_vmaf \\ @default_vmaf_target) do
    case OutputParser.parse_line(line) do
      {:ok, %{type: type, data: data}} ->
        handle_parsed_line(type, data, video, args, target_vmaf)

      :ignore ->
        # Handle custom error patterns not in OutputParser
        if line == "Error: Failed to find a suitable crf" do
          handle_crf_search_error(video, target_vmaf)
        else
          Logger.debug("CrfSearch: Ignoring line: #{line}")
        end
    end
  end

  # Structured line handler using OutputParser's clean approach
  defp handle_parsed_line(type, data, video, args, _target_vmaf) do
    case type do
      :encoding_sample ->
        handle_encoding_sample(data, video)

      :vmaf_result ->
        handle_vmaf_result(data, video, args)

      :sample_vmaf ->
        handle_vmaf_result(data, video, args)

      :dash_vmaf ->
        handle_vmaf_result(data, video, args)

      :eta_vmaf ->
        handle_eta_vmaf(data, video, args)

      :progress ->
        handle_progress(data, video)

      :success ->
        handle_success(data, video)

      :warning ->
        handle_warning(data)

      :vmaf_comparison ->
        handle_vmaf_comparison(data)

      _ ->
        Logger.debug("CrfSearch: Unhandled line type: #{type}")
    end
  end

  # Simplified handler functions using structured data
  defp handle_encoding_sample(data, video) do
    Logger.debug(
      "CrfSearch: Encoding sample #{data.sample_num}/#{data.total_samples}: #{data.crf}"
    )

    broadcast_crf_search_progress(video.path, %CrfSearchProgress{
      filename: video.path,
      crf: data.crf
    })
  end

  defp handle_vmaf_result(data, video, args) do
    Logger.debug("CrfSearch: CRF: #{data.crf}, VMAF: #{data.score}, Percent: #{data.percent}%")

    upsert_vmaf(
      %{
        "crf" => to_string(data.crf),
        "score" => to_string(data.score),
        "percent" => to_string(data.percent),
        "chosen" => "false"
      },
      video,
      args
    )
  end

  defp handle_eta_vmaf(data, video, args) do
    Logger.debug(
      "CrfSearch: CRF: #{data.crf}, VMAF: #{data.score}, size: #{data.size} #{data.unit}, Percent: #{data.percent}%, time: #{data.time} #{data.time_unit}"
    )

    # Check size limit
    estimated_size_bytes = DataConverters.convert_size_to_bytes(to_string(data.size), data.unit)

    if estimated_size_bytes && estimated_size_bytes > @max_file_size_bytes do
      Logger.warning(
        "CrfSearch: VMAF CRF #{Formatters.format_crf(data.crf)} estimated file size (#{Formatters.format_file_size(estimated_size_bytes)}) exceeds 10GB limit for video #{video.id}. Recording VMAF but may fail if chosen."
      )
    end

    upsert_vmaf(
      %{
        "crf" => to_string(data.crf),
        "score" => to_string(data.score),
        "percent" => to_string(data.percent),
        "chosen" => "true",
        "size" => to_string(data.size),
        "unit" => data.unit,
        "time" => to_string(data.time),
        "time_unit" => data.time_unit
      },
      video,
      args
    )
  end

  defp handle_progress(data, video) do
    Logger.debug(
      "CrfSearch Progress: #{data.progress}%, #{Formatters.format_fps(data.fps)}, ETA: #{data.eta}"
    )

    broadcast_crf_search_progress(video.path, %CrfSearchProgress{
      filename: video.path,
      percent: data.progress,
      eta: to_string(data.eta),
      fps: data.fps
    })
  end

  defp handle_success(data, video) do
    Logger.debug("CrfSearch successful for CRF: #{data.crf}")

    # Mark VMAF as chosen first
    Media.mark_vmaf_as_chosen(video.id, to_string(data.crf))

    # Check if the chosen VMAF has a file size estimate that exceeds 10GB
    case get_vmaf_by_crf(video.id, to_string(data.crf)) do
      nil ->
        Logger.warning(
          "CrfSearch: Could not find VMAF record for chosen CRF #{data.crf} for video #{video.id}"
        )

      vmaf ->
        handle_vmaf_size_check(vmaf, video, to_string(data.crf))
    end
  end

  defp handle_warning(data) do
    Logger.info("CrfSearch: Warning: #{data.message}")
  end

  defp handle_vmaf_comparison(data) do
    Logger.debug("VMAF comparison: #{data.file1} vs #{data.file2}")
  end

  # Extract the complex error handling logic to a separate function
  defp handle_crf_search_error(video, target_vmaf) do
    Logger.debug("CrfSearch: Processing error line for video #{video.id}")
    tested_scores = get_vmaf_scores_for_video(video.id)

    error_msg = build_detailed_error_message(target_vmaf, tested_scores, video.path)
    Logger.error(error_msg)

    # Check if we should retry with --preset 6
    retry_result = should_retry_with_preset_6_private(video.id)
    Logger.info("CrfSearch: Retry result: #{inspect(retry_result)}")

    case retry_result do
      {:retry, existing_vmafs} ->
        Logger.info(
          "CrfSearch: Scheduling retry for video #{video.id} (#{Path.basename(video.path)}) with --preset 6 after CRF search failure"
        )

        clear_vmaf_records_for_video_private(video.id, existing_vmafs)
        Process.put(:pending_preset_6_retry, {video, target_vmaf})

      :already_retried ->
        Logger.error(
          "CrfSearch: Video #{video.id} (#{Path.basename(video.path)}) already retried with --preset 6, marking as failed"
        )

        Reencodarr.FailureTracker.record_preset_retry_failure(video, 6, 1,
          context: %{target_vmaf: target_vmaf, tested_scores: tested_scores}
        )

      :mark_failed ->
        Logger.info("CrfSearch: Marking video #{video.id} as failed due to no VMAF records")

        Reencodarr.FailureTracker.record_crf_optimization_failure(
          video,
          target_vmaf,
          tested_scores
        )
    end
  end

  defp handle_vmaf_size_check(vmaf, video, crf) do
    case check_vmaf_size_limit(vmaf, video) do
      :ok ->
        :ok

      {:error, :size_too_large} ->
        handle_size_limit_exceeded(video, crf)
    end
  end

  defp handle_size_limit_exceeded(video, crf) do
    Logger.error(
      "CrfSearch: Chosen VMAF CRF #{crf} exceeds 10GB limit for video #{video.id}. Marking as failed."
    )

    # Record size limit failure with detailed context
    Reencodarr.FailureTracker.record_size_limit_failure(video, "Estimated > 10GB", "10GB",
      context: %{chosen_crf: crf}
    )

    # Publish failure event to PubSub
    Phoenix.PubSub.broadcast(
      Reencodarr.PubSub,
      "crf_search_events",
      {:crf_search_completed, video.id, {:error, :file_size_too_large}}
    )
  end

  # Helper function to get VMAF scores that were tested for this video
  defp get_vmaf_scores_for_video(video_id) do
    import Ecto.Query

    query =
      from v in Media.Vmaf,
        where: v.video_id == ^video_id,
        order_by: [desc: v.score],
        limit: 10,
        select: %{crf: v.crf, score: v.score}

    case Repo.all(query) do
      [] ->
        []

      vmaf_entries ->
        vmaf_entries
        |> Enum.map(fn %{crf: crf, score: score} -> %{crf: crf, score: score} end)
    end
  end

  # Helper function to build a detailed error message
  defp build_detailed_error_message(target_vmaf, tested_scores, video_path) do
    base_msg =
      "Failed to find a suitable CRF for #{Path.basename(video_path)} (target VMAF: #{target_vmaf})"

    case tested_scores do
      [] ->
        "#{base_msg}. No VMAF scores were recorded - this suggests the encoding samples failed completely. Check if ffmpeg and ab-av1 are properly installed and the video file is accessible."

      scores when length(scores) < 3 ->
        max_score = scores |> Enum.map(fn %{score: score} -> score end) |> Enum.max()

        "#{base_msg}. Only #{length(scores)} VMAF score(s) were tested (highest: #{Formatters.format_vmaf_score(max_score)}). The search space may be too limited - try using a wider CRF range or different encoder settings."

      scores ->
        max_score = scores |> Enum.map(fn %{score: score} -> score end) |> Enum.max()
        min_score = scores |> Enum.map(fn %{score: score} -> score end) |> Enum.min()
        score_count = length(scores)

        if max_score < target_vmaf do
          gap = target_vmaf - max_score

          "#{base_msg}. Tested #{score_count} CRF values with VMAF scores ranging from #{Formatters.format_vmaf_score(min_score)} to #{Formatters.format_vmaf_score(max_score)}. The highest quality (#{Formatters.format_vmaf_score(max_score)}) is still #{Formatters.format_vmaf_score(gap)} points below the target. Try lowering the target VMAF or using a higher quality encoder preset."
        else
          "#{base_msg}. Tested #{score_count} CRF values with VMAF scores ranging from #{Formatters.format_vmaf_score(min_score)} to #{Formatters.format_vmaf_score(max_score)}. The search algorithm couldn't converge on a suitable CRF value - this may indicate an issue with the binary search algorithm or encoder settings."
        end
    end
  end

  defp build_crf_search_args(video, vmaf_percent) do
    base_args = [
      "crf-search",
      "--input",
      video.path,
      "--min-vmaf",
      Integer.to_string(vmaf_percent),
      "--temp-dir",
      Helper.temp_dir()
    ]

    # Use centralized Rules module to handle all argument building and deduplication
    Reencodarr.Rules.build_args(video, :crf_search, [], base_args)
  end

  # Build CRF search args with --preset 6 added
  defp build_crf_search_args_with_preset_6_private(video, vmaf_percent) do
    base_args = [
      "crf-search",
      "--input",
      video.path,
      "--min-vmaf",
      Integer.to_string(vmaf_percent),
      "--temp-dir",
      Helper.temp_dir()
    ]

    # Use centralized Rules module with preset 6 additional param
    Reencodarr.Rules.build_args(video, :crf_search, ["--preset", "6"], base_args)
  end

  defp upsert_vmaf(params, video, args) do
    time = Time.parse_time_to_seconds(params["time"], params["time_unit"])

    size_info =
      case {params["size"], params["unit"]} do
        {nil, _} -> nil
        {_, nil} -> nil
        {size, unit} -> "#{size} #{unit}"
      end

    # Calculate savings based on percent and video size
    savings = DataConverters.calculate_savings(params["percent"], video.size)

    vmaf_data =
      Map.merge(params, %{
        "video_id" => video.id,
        "params" => Helper.remove_args(args, ["--min-vmaf", "crf-search"]),
        "time" => time,
        "size" => size_info,
        "savings" => savings,
        "target" => @default_vmaf_target
      })

    case Media.upsert_vmaf(vmaf_data) do
      {:ok, created_vmaf} ->
        Logger.debug("Upserted VMAF: #{inspect(created_vmaf)}")
        broadcast_crf_search_progress(video.path, created_vmaf)
        created_vmaf

      {:error, changeset} ->
        Logger.error("Failed to upsert VMAF: #{inspect(changeset)}")
        nil
    end
  end

  defp broadcast_crf_search_progress(video_path, progress_data) do
    filename = Path.basename(video_path)

    progress =
      case progress_data do
        %CrfSearchProgress{} = existing_progress ->
          # Update filename to ensure it's consistent
          %{existing_progress | filename: filename}

        vmaf when is_map(vmaf) ->
          # Convert VMAF struct to CrfSearchProgress
          crf_value = DataConverters.convert_to_number(vmaf.crf)
          score_value = DataConverters.convert_to_number(vmaf.score)
          percent_value = DataConverters.convert_to_number(vmaf.percent)

          Logger.debug(
            "CrfSearch: Converting VMAF to progress - CRF: #{inspect(crf_value)}, Score: #{inspect(score_value)}, Percent: #{inspect(percent_value)}"
          )

          # Include all fields - the telemetry reporter will handle smart merging
          %CrfSearchProgress{
            filename: filename,
            percent: percent_value,
            crf: crf_value,
            score: score_value
          }

        invalid_data ->
          Logger.warning("CrfSearch: Invalid progress data received: #{inspect(invalid_data)}")
          %CrfSearchProgress{filename: filename}
      end

    # Debounce telemetry updates to avoid overwhelming the dashboard
    if should_emit_progress?(filename, progress) do
      case emit_progress_safely(progress) do
        :ok ->
          update_last_progress(filename, progress)
          :ok

        {:error, reason} ->
          Logger.error("CrfSearch: Failed to emit progress for #{video_path}: #{inspect(reason)}")
      end
    end
  end

  # Debouncing logic to prevent too many telemetry updates
  defp should_emit_progress?(filename, progress) do
    cache_key = {:crf_progress, filename}
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(cache_key, nil) do
      nil ->
        # First progress update for this file
        true

      {last_time, last_progress} ->
        time_since_last = now - last_time

        # Balanced debouncing: 5 seconds OR major progress change (>50%)
        cond do
          time_since_last > 5_000 ->
            true

          # Only emit for major progress jumps (>50% change)
          significant_change?(last_progress, progress) ->
            true

          # Otherwise debounce everything
          true ->
            false
        end
    end
  end

  defp update_last_progress(filename, progress) do
    cache_key = {:crf_progress, filename}
    now = System.monotonic_time(:millisecond)
    :persistent_term.put(cache_key, {now, progress})
  end

  defp significant_change?(last_progress, new_progress) do
    case {last_progress.percent, new_progress.percent} do
      {nil, _} ->
        true

      {_, nil} ->
        true

      {last_percent, new_percent} when is_number(last_percent) and is_number(new_percent) ->
        abs(new_percent - last_percent) > 50.0

      _ ->
        true
    end
  end

  # Safely emit telemetry progress
  defp emit_progress_safely(progress) do
    Telemetry.emit_crf_search_progress(progress)
    :ok
  rescue
    error -> {:error, error}
  end

  # Convert size with unit to bytes
  # Get VMAF record by video ID and CRF value
  defp get_vmaf_by_crf(video_id, crf_str) do
    case Float.parse(crf_str) do
      {crf_float, _} ->
        import Ecto.Query

        query =
          from v in Media.Vmaf,
            where: v.video_id == ^video_id and v.crf == ^crf_float,
            limit: 1

        Repo.one(query)

      :error ->
        nil
    end
  end

  # Check if VMAF's estimated size exceeds 10GB limit
  defp check_vmaf_size_limit(vmaf, video) do
    case vmaf.size do
      nil ->
        # No size info available, allow it
        :ok

      size_str when is_binary(size_str) ->
        check_size_string_limit(size_str, video)

      _ ->
        :ok
    end
  end

  defp check_size_string_limit(size_str, video) do
    # Parse size string like "12.5 GB" or "8.2 MB"
    case Regex.run(~r/^(\d+\.?\d*)\s+(\w+)$/, String.trim(size_str)) do
      [_, size_value, unit] ->
        validate_size_limit(size_value, unit, video)

      _ ->
        :ok
    end
  end

  defp validate_size_limit(size_value, unit, video) do
    estimated_size_bytes = DataConverters.convert_size_to_bytes(size_value, unit)

    if estimated_size_bytes && estimated_size_bytes > @max_file_size_bytes do
      Logger.info(
        "CrfSearch: VMAF estimated size #{Formatters.format_file_size(estimated_size_bytes)} exceeds 10GB limit for video #{video.id}"
      )

      {:error, :size_too_large}
    else
      :ok
    end
  end

  # Determine if we should retry with preset 6 based on video ID
  defp should_retry_with_preset_6_private(video_id) do
    import Ecto.Query

    # Get existing VMAF records for this video
    existing_vmafs =
      from(v in Media.Vmaf, where: v.video_id == ^video_id)
      |> Repo.all()

    case existing_vmafs do
      [] ->
        # No existing records, mark as failed (no point retrying with preset 6 if we haven't tried anything yet)
        :mark_failed

      vmafs ->
        # Check if any existing record was done with --preset 6
        has_preset_6 = Enum.any?(vmafs, &vmaf_has_preset_6?/1)

        # Check if we have too many failed attempts (more than 3 VMAF records suggests multiple failures)
        cond do
          length(vmafs) > 3 -> :mark_failed
          has_preset_6 -> :already_retried
          true -> {:retry, vmafs}
        end
    end
  end

  defp vmaf_has_preset_6?(vmaf) do
    case vmaf.params do
      nil ->
        false

      params_string when is_binary(params_string) ->
        String.contains?(params_string, "--preset 6")

      params_list when is_list(params_list) ->
        has_preset_6_in_list?(params_list)

      _ ->
        false
    end
  end

  # Clear VMAF records for a video (used for test cleanup)
  defp clear_vmaf_records_for_video_private(video_id, vmaf_records) when is_list(vmaf_records) do
    import Ecto.Query

    vmaf_ids = Enum.map(vmaf_records, & &1.id)

    from(v in Media.Vmaf, where: v.video_id == ^video_id and v.id in ^vmaf_ids)
    |> Repo.delete_all()
  end

  # Helper to check for --preset 6 in a list of parameters
  defp has_preset_6_in_list?([]), do: false
  defp has_preset_6_in_list?([_]), do: false
  defp has_preset_6_in_list?(["--preset", "6" | _]), do: true
  defp has_preset_6_in_list?([_ | rest]), do: has_preset_6_in_list?(rest)

  # === Helper Functions ===

  # Broadcast CRF search completion event to PubSub
  defp broadcast_crf_search_completion(video_id, result) do
    Phoenix.PubSub.broadcast(
      Reencodarr.PubSub,
      "crf_search_events",
      {:crf_search_completed, video_id, result}
    )
  end
end
