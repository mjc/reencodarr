defmodule Reencodarr.AbAv1.CrfSearch do
  @moduledoc """
  GenServer for handling CRF search operations using ab-av1.

  This module manages the CRF search process for videos to find optimal
  encoding parameters based on VMAF quality targets.
  """

  use GenServer

  alias Reencodarr.AbAv1.Helper
  alias Reencodarr.CrfSearcher.Broadway.Producer
  alias Reencodarr.{Media, Repo, Telemetry}
  alias Reencodarr.Statistics.CrfSearchProgress

  require Logger

  # Common regex fragments to reduce duplication
  @crf_pattern "(?<crf>\\d+(?:\\.\\d+)?)"
  @vmaf_score_pattern "(?<score>\\d+\\.\\d+)"
  @percent_pattern "\\((?<percent>\\d+)%\\)"
  @timestamp_pattern "\\[(?<timestamp>[^\\]]+)\\]"
  @fps_pattern "(?<fps>\\d+(?:\\.\\d+)?)\\sfps?"
  @eta_pattern "eta\\s(?<eta>\\d+\\s(?:second|minute|hour|day|week|month|year)s?)"
  @time_unit_pattern "(?<time_unit>second|minute|hour|day|week|month|year)s?"

  # Centralized regex patterns for different line types
  @patterns %{
    encoding_sample: ~r/
      encoding\ssample\s
      (?<sample_num>\d+)\/             # Capture sample number
      (?<total_samples>\d+)\s          # Capture total samples
      crf\s#{@crf_pattern}             # Capture CRF value
    /x,
    simple_vmaf: ~r/
      #{@timestamp_pattern}\s
      .*?
      crf\s#{@crf_pattern}\s          # Capture CRF value
      VMAF\s#{@vmaf_score_pattern}\s  # Capture VMAF score
      #{@percent_pattern}             # Capture percentage
    /x,
    sample_vmaf: ~r/
      sample\s
      (?<sample_num>\d+)\/             # Capture sample number
      (?<total_samples>\d+)\s          # Capture total samples
      crf\s#{@crf_pattern}\s          # Capture CRF value
      VMAF\s#{@vmaf_score_pattern}\s  # Capture VMAF score
      #{@percent_pattern}             # Capture percentage
      (?:\s\(.*\))?
    /x,
    dash_vmaf: ~r/
      ^-\s                             # Lines starting with dash and space
      crf\s#{@crf_pattern}\s          # Capture CRF value
      VMAF\s#{@vmaf_score_pattern}\s  # Capture VMAF score
      #{@percent_pattern}             # Capture percentage
      (?:\s\(.*\))?                   # Optional parentheses content like (cache)
    /x,
    eta_vmaf: ~r/
      crf\s#{@crf_pattern}\s          # Capture CRF value
      VMAF\s#{@vmaf_score_pattern}\s  # Capture VMAF score
      predicted\svideo\sstream\ssize\s
      (?<size>\d+\.?\d*)\s             # Capture size (allow integers or decimals)
      (?<unit>\w+)\s                   # Capture unit
      #{@percent_pattern}\s           # Capture percentage
      taking\s
      (?<time>\d+\.?\d*)\s             # Capture time (allow integers or decimals)
      #{@time_unit_pattern}           # Capture time unit with optional plural
      (?:\s\(.*\))?
    /x,
    vmaf_comparison: ~r/
      vmaf\s
      (?<file1>.+?)\s                  # Capture first file name
      vs\sreference\s
      (?<file2>.+)                     # Capture second file name
    /x,
    progress: ~r/
      #{@timestamp_pattern}\s
      .*?
      (?<progress>\d+(?:\.\d+)?)%,\s
      #{@fps_pattern},\s              # Updated to exclude "fps" from the capture group
      #{@eta_pattern}
    /x,
    success: ~r/
      (?:\[.*\]\s)?                   # Optional timestamp prefix
      crf\s#{@crf_pattern}\s          # Capture CRF value from this one to know which CRF was selected.
      successful
    /x,
    warning: ~r/
      ^Warning:\s                     # Lines starting with "Warning: "
      .*                             # Followed by any text
    /x
  }

  # Unified line matching function using pattern keys
  defp match_line(line, pattern_key) do
    pattern = Map.get(@patterns, pattern_key)

    case Regex.named_captures(pattern, line) do
      nil -> nil
      captures -> captures
    end
  end

  # Public API
  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec crf_search(Media.Video.t(), integer()) :: :ok
  def crf_search(%Media.Video{reencoded: true, path: path, id: video_id}, _vmaf_percent) do
    Logger.debug("Skipping crf search for video #{path} as it is already reencoded")

    # Publish skipped event to PubSub
    Phoenix.PubSub.broadcast(
      Reencodarr.PubSub,
      "crf_search_events",
      {:crf_search_completed, video_id, :skipped}
    )

    :ok
  end

  def crf_search(%Media.Video{} = video, vmaf_percent) do
    if Media.chosen_vmaf_exists?(video) do
      Logger.debug("Skipping crf search for video #{video.path} as a chosen VMAF already exists")

      # Publish skipped event to PubSub
      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        "crf_search_events",
        {:crf_search_completed, video.id, :skipped}
      )
    else
      Logger.info(
        "Initiating crf search for video #{video.id} (#{Path.basename(video.path)}) with target VMAF: #{vmaf_percent}"
      )

      GenServer.cast(__MODULE__, {:crf_search, video, vmaf_percent})
    end

    :ok
  end

  def running? do
    GenServer.call(__MODULE__, :running?) == :running
  end

  # Test helpers - only available in test environment
  if Mix.env() == :test do
    def has_preset_6_params?(params), do: has_preset_6_params_private(params)
    def should_retry_with_preset_6(video_id), do: should_retry_with_preset_6_private(video_id)

    # Legacy test function names for backward compatibility
    def has_preset_6_params_for_test(params), do: has_preset_6_params_private(params)

    def should_retry_with_preset_6_for_test(video_id),
      do: should_retry_with_preset_6_private(video_id)

    def build_crf_search_args_with_preset_6_for_test(video, vmaf_percent),
      do: build_crf_search_args_with_preset_6(video, vmaf_percent)

    def clear_vmaf_records_for_video(video_id, vmaf_records),
      do: clear_vmaf_records_for_video_private(video_id, vmaf_records)

    def build_crf_search_args_with_preset_6(video, vmaf_percent),
      do: build_crf_search_args_with_preset_6_private(video, vmaf_percent)

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
  def handle_info(:refresh_stats, state) do
    # Legacy message from old statistics system - ignore since we now use telemetry
    {:noreply, state}
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
    Logger.debug("CRF search finished successfully for video #{video.id}")

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

    # Check if we should retry with --preset 6 on process failure as well
    case should_retry_with_preset_6_private(video.id) do
      {:retry, existing_vmafs} ->
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

      :already_retried ->
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

      :mark_failed ->
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

  @impl true
  def handle_continue({:preset_6_retry, video, target_vmaf}, state) do
    Logger.info("CrfSearch: Executing preset 6 retry for video #{video.id} via handle_continue")
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

  defp append_decimal_before_float(str) do
    str
    |> then(fn s -> if String.contains?(s, "."), do: s, else: s <> ".0" end)
    |> String.to_float()
  end

  def process_line(line, video, args, target_vmaf \\ 95) do
    handlers = [
      &handle_encoding_sample_line/2,
      fn l, v -> handle_vmaf_line(l, v, args) end,
      fn l, v -> handle_eta_vmaf_line(l, v, args) end,
      fn l, _v -> handle_vmaf_comparison_line(l) end,
      &handle_progress_line/2,
      &handle_success_line/2,
      &handle_warning_line/2,
      fn l, v -> handle_error_line(l, v, target_vmaf) end
    ]

    case Enum.find(handlers, fn handler -> handler.(line, video) end) do
      nil -> Logger.error("CrfSearch: No match for line: #{line}")
      _handler -> :ok
    end
  end

  defp handle_encoding_sample_line(line, video) do
    case match_line(line, :encoding_sample) do
      nil ->
        false

      captures ->
        Logger.debug(
          "CrfSearch: Encoding sample #{captures["sample_num"]}/#{captures["total_samples"]}: #{captures["crf"]}"
        )

        broadcast_crf_search_progress(video.path, %CrfSearchProgress{
          filename: video.path,
          crf: append_decimal_before_float(captures["crf"])
        })

        true
    end
  end

  defp handle_vmaf_line(line, video, args) do
    # Try simple VMAF pattern first, then sample pattern as fallback
    case try_patterns(line, [:simple_vmaf, :sample_vmaf, :dash_vmaf]) do
      nil ->
        false

      captures ->
        Logger.debug(
          "CrfSearch: CRF: #{captures["crf"]}, VMAF: #{captures["score"]}, Percent: #{captures["percent"]}%"
        )

        upsert_vmaf(Map.put(captures, "chosen", false), video, args)
        true
    end
  end

  defp try_patterns(line, patterns) do
    Enum.find_value(patterns, fn pattern ->
      match_line(line, pattern)
    end)
  end

  defp handle_eta_vmaf_line(line, video, args) do
    case match_line(line, :eta_vmaf) do
      nil ->
        false

      captures ->
        Logger.debug(
          "CrfSearch: CRF: #{captures["crf"]}, VMAF: #{captures["score"]}, size: #{captures["size"]} #{captures["unit"]}, Percent: #{captures["percent"]}%, time: #{captures["time"]} #{captures["time_unit"]}"
        )

        # Always insert the VMAF record, but log a warning if size exceeds 10GB
        estimated_size_bytes = convert_size_to_bytes(captures["size"], captures["unit"])
        # 10GB in bytes
        max_size_bytes = 10 * 1024 * 1024 * 1024

        if estimated_size_bytes && estimated_size_bytes > max_size_bytes do
          estimated_size_gb = estimated_size_bytes / (1024 * 1024 * 1024)

          Logger.warning(
            "CrfSearch: VMAF CRF #{captures["crf"]} estimated file size (#{Float.round(estimated_size_gb, 2)} GB) exceeds 10GB limit for video #{video.id}. Recording VMAF but may fail if chosen."
          )
        end

        upsert_vmaf(Map.put(captures, "chosen", true), video, args)
        true
    end
  end

  defp handle_vmaf_comparison_line(line) do
    case match_line(line, :vmaf_comparison) do
      nil ->
        false

      captures ->
        Logger.debug("VMAF comparison: #{captures["file1"]} vs #{captures["file2"]}")
        true
    end
  end

  defp handle_progress_line(line, video) do
    case match_line(line, :progress) do
      nil ->
        false

      captures ->
        Logger.debug(
          "CrfSearch Progress: #{captures["progress"]}, FPS: #{captures["fps"]}, ETA: #{captures["eta"]}"
        )

        percent = append_decimal_before_float(captures["progress"])
        fps = append_decimal_before_float(captures["fps"])

        broadcast_crf_search_progress(video.path, %CrfSearchProgress{
          filename: video.path,
          percent: percent,
          eta: captures["eta"],
          fps: fps
        })

        true
    end
  end

  defp handle_success_line(line, video) do
    case match_line(line, :success) do
      nil ->
        false

      captures ->
        Logger.debug("CrfSearch successful for CRF: #{captures["crf"]}")

        # Mark VMAF as chosen first
        Media.mark_vmaf_as_chosen(video.id, captures["crf"])

        # Check if the chosen VMAF has a file size estimate that exceeds 10GB
        case get_vmaf_by_crf(video.id, captures["crf"]) do
          nil ->
            Logger.warning(
              "CrfSearch: Could not find VMAF record for chosen CRF #{captures["crf"]} for video #{video.id}"
            )

          vmaf ->
            handle_vmaf_size_check(vmaf, video, captures["crf"])
        end

        true
    end
  end

  defp handle_warning_line(line, _video) do
    case match_line(line, :warning) do
      nil ->
        false

      _captures ->
        # Log the warning at info level so tests can capture it
        Logger.info("CrfSearch: #{line}")
        true
    end
  end

  defp handle_vmaf_size_check(vmaf, video, crf) do
    case check_vmaf_size_limit(vmaf, video) do
      :ok ->
        Logger.info(
          "CrfSearch: Chosen VMAF CRF #{crf} is within size limits for video #{video.id}"
        )

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

  defp handle_error_line(line, video, target_vmaf) do
    if line == "Error: Failed to find a suitable crf" do
      Logger.info("CrfSearch: Processing error line for video #{video.id}")
      Logger.info("CrfSearch: About to get VMAF scores")
      tested_scores = get_vmaf_scores_for_video(video.id)
      Logger.info("CrfSearch: Got tested scores: #{inspect(tested_scores)}")

      error_msg = build_detailed_error_message(target_vmaf, tested_scores, video.path)
      Logger.error(error_msg)

      # Check if we should retry with --preset 6
      Logger.info("CrfSearch: About to check retry logic for video #{video.id}")
      retry_result = should_retry_with_preset_6_private(video.id)
      Logger.info("CrfSearch: Retry result: #{inspect(retry_result)}")

      case retry_result do
        {:retry, existing_vmafs} ->
          Logger.info(
            "CrfSearch: Scheduling retry for video #{video.id} (#{Path.basename(video.path)}) with --preset 6 after CRF search failure"
          )

          # Clear existing VMAF records for this video to start fresh
          clear_vmaf_records_for_video_private(video.id, existing_vmafs)

          # Mark that we should retry when the current process exits
          # Store retry info for later processing
          Process.put(:pending_preset_6_retry, {video, target_vmaf})

        :already_retried ->
          Logger.error(
            "CrfSearch: Video #{video.id} (#{Path.basename(video.path)}) already retried with --preset 6, marking as failed"
          )

          # Record preset retry failure
          Reencodarr.FailureTracker.record_preset_retry_failure(video, 6, 1,
            context: %{target_vmaf: target_vmaf, tested_scores: tested_scores}
          )

        :mark_failed ->
          Logger.info("CrfSearch: Marking video #{video.id} as failed due to no VMAF records")

          # Record CRF optimization failure
          Reencodarr.FailureTracker.record_crf_optimization_failure(
            video,
            target_vmaf,
            tested_scores
          )
      end

      true
    else
      false
    end
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

        "#{base_msg}. Only #{length(scores)} VMAF score(s) were tested (highest: #{Float.round(max_score, 2)}). The search space may be too limited - try using a wider CRF range or different encoder settings."

      scores ->
        max_score = scores |> Enum.map(fn %{score: score} -> score end) |> Enum.max()
        min_score = scores |> Enum.map(fn %{score: score} -> score end) |> Enum.min()
        score_count = length(scores)

        if max_score < target_vmaf do
          gap = target_vmaf - max_score

          "#{base_msg}. Tested #{score_count} CRF values with VMAF scores ranging from #{Float.round(min_score, 2)} to #{Float.round(max_score, 2)}. The highest quality (#{Float.round(max_score, 2)}) is still #{Float.round(gap, 2)} points below the target. Try lowering the target VMAF or using a higher quality encoder preset."
        else
          "#{base_msg}. Tested #{score_count} CRF values with VMAF scores ranging from #{Float.round(min_score, 2)} to #{Float.round(max_score, 2)}. The search algorithm couldn't converge on a suitable CRF value - this may indicate an issue with the binary search algorithm or encoder settings."
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
    time = parse_time(params["time"], params["time_unit"])

    size_info =
      case {params["size"], params["unit"]} do
        {nil, _} -> nil
        {_, nil} -> nil
        {size, unit} -> "#{size} #{unit}"
      end

    # Calculate savings based on percent and video size
    savings = calculate_savings(params["percent"], video.size)

    vmaf_data =
      Map.merge(params, %{
        "video_id" => video.id,
        "params" => Helper.remove_args(args, ["--min-vmaf", "crf-search"]),
        "time" => time,
        "size" => size_info,
        "savings" => savings,
        "target" => 95
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
          crf_value = convert_to_number(vmaf.crf)
          score_value = convert_to_number(vmaf.score)
          percent_value = convert_to_number(vmaf.percent)

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

    # Always emit progress data - the reporter will handle smart merging
    case emit_progress_safely(progress) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("CrfSearch: Failed to emit progress for #{video_path}: #{inspect(reason)}")
    end
  end

  # Safely emit telemetry progress
  defp emit_progress_safely(progress) do
    Telemetry.emit_crf_search_progress(progress)
    :ok
  rescue
    error -> {:error, error}
  end

  defp convert_to_number(nil), do: nil
  defp convert_to_number(val) when is_number(val), do: val

  defp convert_to_number(val) when is_binary(val) do
    case Float.parse(val) do
      {num, _} -> num
      :error -> nil
    end
  end

  defp convert_to_number(_), do: nil

  # Convert size with unit to bytes
  defp convert_size_to_bytes(size_str, unit) when is_binary(size_str) and is_binary(unit) do
    with {size_value, _} <- Float.parse(size_str),
         multiplier when not is_nil(multiplier) <- get_unit_multiplier(unit) do
      round(size_value * multiplier)
    else
      _ -> nil
    end
  end

  defp convert_size_to_bytes(_, _), do: nil

  # Get the byte multiplier for a given unit
  defp get_unit_multiplier(unit) do
    case String.downcase(unit) do
      "b" -> 1
      "kb" -> 1024
      "mb" -> 1024 * 1024
      "gb" -> 1024 * 1024 * 1024
      "tb" -> 1024 * 1024 * 1024 * 1024
      _ -> nil
    end
  end

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
    estimated_size_bytes = convert_size_to_bytes(size_value, unit)
    # 10GB in bytes
    max_size_bytes = 10 * 1024 * 1024 * 1024

    if estimated_size_bytes && estimated_size_bytes > max_size_bytes do
      estimated_size_gb = estimated_size_bytes / (1024 * 1024 * 1024)

      Logger.info(
        "CrfSearch: VMAF estimated size #{Float.round(estimated_size_gb, 2)} GB exceeds 10GB limit for video #{video.id}"
      )

      {:error, :size_too_large}
    else
      :ok
    end
  end

  defp parse_time(nil, _), do: nil
  defp parse_time(_, nil), do: nil

  defp parse_time(time, time_unit) do
    case Integer.parse(time) do
      {time_value, _} -> Helper.convert_to_seconds(time_value, time_unit)
      :error -> nil
    end
  end

  # Calculate estimated space savings in bytes based on percent and video size
  defp calculate_savings(nil, _video_size), do: nil
  defp calculate_savings(_percent, nil), do: nil

  defp calculate_savings(percent, video_size) when is_binary(percent) do
    case Float.parse(percent) do
      {percent_float, _} -> calculate_savings(percent_float, video_size)
      :error -> nil
    end
  end

  defp calculate_savings(percent, video_size) when is_number(percent) and is_number(video_size) do
    if percent > 0 and percent <= 100 do
      # Savings = (100 - percent) / 100 * original_size
      round((100 - percent) / 100 * video_size)
    else
      nil
    end
  end

  defp calculate_savings(_, _), do: nil

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
end
