defmodule Reencodarr.AbAv1.CrfSearch do
  @moduledoc """
  GenServer for handling CR  @impl true
  def handle_cast({:crf_search_with_preset_6, video, vmaf_percent}, %{port: :none} = state) do
    args = build_crf_search_args_with_preset_6(video, vmaf_percent)

    new_state = %{
      state
      | port: Helper.open_port(args),
        current_task: %{video: video, args: args, target_vmaf: vmaf_percent},
        output_buffer: []
    }perations using ab-av1.

  This module manages the CRF search process for videos to find optimal
  encoding parameters based on VMAF quality targets.
  """

  use GenServer

  alias Reencodarr.AbAv1.CrfSearch.RetryLogic
  alias Reencodarr.AbAv1.{Helper, ProgressParser}
  alias Reencodarr.CrfSearcher.Broadway.Producer
  alias Reencodarr.ErrorHelpers
  alias Reencodarr.{Media, Rules, Telemetry}

  require Logger

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

  # Test helpers
  def has_preset_6_params?(params), do: Media.has_preset_6_params?(params)
  def should_retry_with_preset_6(video_id), do: RetryLogic.should_retry_with_preset_6(video_id)

  def clear_vmaf_records_for_video(video_id, vmaf_records),
    do: Media.clear_vmaf_records(video_id, vmaf_records)

  # Public functions for argument building (used in tests and internally)

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
    args = build_crf_search_args_with_preset_6(video, vmaf_percent)

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

    # Create state for ProgressParser with CRF search context
    progress_state = %{
      video: video,
      args: args,
      target_vmaf: target_vmaf
    }

    case ProgressParser.process_line(full_line, progress_state) do
      :error_pattern ->
        # Handle the specific CRF search error pattern
        RetryLogic.handle_crf_search_error(video, target_vmaf)

      _ ->
        :ok
    end

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
    # Get chosen VMAF for logging
    chosen_vmaf = Reencodarr.Media.get_chosen_vmaf_for_video(video.id)

    success_msg =
      case chosen_vmaf do
        %{crf: crf, score: score} ->
          "✅ AbAv1: CRF search completed for video #{video.id} (#{video.title}) - Chosen CRF #{crf} with VMAF #{score}"

        _ ->
          "✅ AbAv1: CRF search completed for video #{video.id} (#{video.title})"
      end

    Logger.info(success_msg)

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
    # Capture the full command output for failure analysis
    full_output = output_buffer |> Enum.reverse() |> Enum.join("\n")
    command_line = "ab-av1 " <> Enum.join(args, " ")

    # Extract meaningful error info from ab-av1 output
    error_summary = extract_error_summary(full_output, exit_code)

    Logger.error(
      "CRF search failed for video #{video.id} (#{Path.basename(video.path)}) with exit code #{exit_code}: #{error_summary}"
    )

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
    case RetryLogic.should_retry_with_preset_6(video.id) do
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
    Media.clear_vmaf_records(video.id, existing_vmafs)

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

  def build_crf_search_args(video, vmaf_percent) do
    base_args = [
      "crf-search",
      "--input",
      video.path,
      "--min-vmaf",
      Integer.to_string(vmaf_percent),
      "--temp-dir",
      Helper.temp_dir(),
      "--thorough"
    ]

    # Use centralized Rules module to handle all argument building and deduplication
    Rules.build_args(video, :crf_search, [], base_args)
  end

  # Build CRF search args with --preset 6 added
  def build_crf_search_args_with_preset_6(video, vmaf_percent) do
    base_args = [
      "crf-search",
      "--input",
      video.path,
      "--min-vmaf",
      Integer.to_string(vmaf_percent),
      "--temp-dir",
      Helper.temp_dir(),
      "--thorough"
    ]

    # Use centralized Rules module with preset 6 and cache disabled for retries
    Rules.build_args(video, :crf_search, ["--preset", "6", "--cache", "false"], base_args)
  end

  # Broadcast CRF search completion event to PubSub
  defp broadcast_crf_search_completion(video_id, result) do
    Phoenix.PubSub.broadcast(
      Reencodarr.PubSub,
      "crf_search_events",
      {:crf_search_completed, video_id, result}
    )
  end

  # Extract meaningful error summary from ab-av1 output
  defp extract_error_summary(output, exit_code) do
    case categorize_error(output) do
      nil -> extract_error_line_from_output(output, exit_code)
      error_message -> error_message
    end
  end

  # Categorize known error patterns
  defp categorize_error(output) do
    error_patterns()
    |> Enum.find_value(&check_error_pattern(output, &1))
  end

  # Define error patterns and their corresponding messages
  defp error_patterns do
    [
      {"No such file or directory", "Input file not found"},
      {"Permission denied", "Permission denied accessing file"},
      {"Invalid argument", "Invalid arguments provided to ab-av1"},
      {"a value is required for", "Missing required argument value"},
      {"unrecognized", "Unrecognized command line option"},
      {"No space left on device", "Insufficient disk space"},
      {"Killed", "Process killed (likely out of memory)"}
    ] ++ compound_error_patterns()
  end

  # Define compound error patterns that require multiple checks
  defp compound_error_patterns do
    [
      {["ffmpeg", "error"], "FFmpeg error during processing"},
      {["vmaf", "error"], "VMAF calculation error"}
    ]
  end

  # Check if an error pattern matches the output
  defp check_error_pattern(output, {pattern, message}) when is_binary(pattern) do
    if String.contains?(output, pattern), do: message
  end

  defp check_error_pattern(output, {patterns, message}) when is_list(patterns) do
    if Enum.all?(patterns, &String.contains?(output, &1)), do: message
  end

  # Extract the last error line from output when no known pattern matches
  defp extract_error_line_from_output(output, exit_code) do
    error_lines =
      output
      |> String.split("\n")
      |> Enum.filter(&contains_error_keywords?/1)
      |> Enum.take(-1)

    case error_lines do
      [last_error | _] -> String.trim(last_error)
      [] -> "Unknown error (exit code #{exit_code})"
    end
  end

  # Check if a line contains error keywords
  defp contains_error_keywords?(line) do
    downcased = String.downcase(line)

    String.contains?(downcased, "error") or
      String.contains?(downcased, "failed") or
      String.contains?(downcased, "fatal")
  end
end
