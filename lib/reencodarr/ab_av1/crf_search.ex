defmodule Reencodarr.AbAv1.CrfSearch do
  @moduledoc """
  GenServer for handling CRF search operations using ab-av1.

  This module manages the CRF search process for videos to find optimal
  encoding parameters based on VMAF quality targets.
  """

  use GenServer

  import Ecto.Query

  alias Reencodarr.AbAv1.Helper
  alias Reencodarr.AbAv1.OutputParser
  alias Reencodarr.Core.Parsers
  alias Reencodarr.Core.Retry
  alias Reencodarr.Core.Time
  alias Reencodarr.CrfSearchHints
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Formatters
  alias Reencodarr.Media
  alias Reencodarr.Repo

  require Logger

  # Updated line matching function using centralized OutputParser with proper type conversion
  defp parse_line_with_types(line) do
    OutputParser.parse_line(line)
  end

  # Public API
  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec crf_search(map(), integer()) :: :ok | :error
  def crf_search(video, _vmaf_percent) when is_nil(video.id), do: :error

  def crf_search(video, _vmaf_percent) when video.state == :encoded do
    Logger.info("Skipping crf search for video #{video.path} as it is already encoded")

    # Clean dashboard event
    Events.broadcast_event(:crf_search_completed, %{
      video_id: video.id,
      result: :skipped
    })

    :ok
  end

  def crf_search(video, _vmaf_percent) when video.state != :analyzed do
    Logger.info(
      "Skipping crf search for video #{video.path} as it is not analyzed (state: #{inspect(video.state)})"
    )

    :error
  end

  def crf_search(video, vmaf_percent) do
    if Media.chosen_vmaf_exists?(video) do
      Logger.info("Skipping crf search for video #{video.path} as a chosen VMAF already exists")
    else
      GenServer.cast(__MODULE__, {:crf_search, video, vmaf_percent})
    end

    :ok
  end

  def running? do
    # Simplified - just check if process exists and is alive
    case GenServer.whereis(__MODULE__) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  def available? do
    # Check if the process exists and is not busy (port is :none)
    case GenServer.whereis(__MODULE__) do
      nil ->
        false

      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, :available?, 1000)
        catch
          :exit, _ -> false
        end
    end
  end

  def get_state do
    # Get the current state for debugging
    case GenServer.whereis(__MODULE__) do
      nil ->
        {:error, :not_running}

      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, :get_state, 1000)
        catch
          :exit, _ -> {:error, :timeout}
        end
    end
  end

  def reset_if_stuck do
    # Force reset the GenServer if it's stuck
    case GenServer.whereis(__MODULE__) do
      nil ->
        {:error, :not_running}

      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, :reset_if_stuck, 1000)
        catch
          :exit, _ -> {:error, :timeout}
        end
    end
  end

  # GenServer callbacks
  @impl true
  def init(:ok) do
    # Enable trap_exit to handle port crashes gracefully
    Process.flag(:trap_exit, true)

    # Kill any orphaned ab-av1 crf-search processes from previous crashes
    Helper.kill_orphaned_processes("ab-av1 crf-search")

    {:ok,
     %{port: :none, current_task: :none, partial_line_buffer: "", output_buffer: [], os_pid: nil}}
  end

  @impl true
  def terminate(reason, state) do
    Logger.warning("CrfSearch GenServer terminating: #{inspect(reason)}")

    # Kill the process group to ensure ffmpeg children are also killed
    Helper.kill_process_group(state.os_pid)

    # Close the port if it's open
    Helper.close_port(state.port)

    # Best-effort: reset video state so it can be re-queued
    reset_video_on_terminate(state)

    :ok
  end

  defp reset_video_on_terminate(%{current_task: :none}), do: :ok

  defp reset_video_on_terminate(%{current_task: %{video: video}}) do
    if is_struct(video, Reencodarr.Media.Video) do
      case Media.mark_as_analyzed(video) do
        {:ok, _} ->
          Logger.info("Reset video #{video.id} to analyzed state for re-queue")

        {:error, reason} ->
          Logger.error("Failed to reset video #{video.id} to analyzed: #{inspect(reason)}")
      end
    end
  end

  @impl true
  def handle_cast({:crf_search, video, vmaf_percent}, %{port: :none} = state) do
    crf_range = CrfSearchHints.crf_range(video)
    start_crf_search(video, vmaf_percent, crf_range, state)
  end

  def handle_cast({:crf_search_retry, video, vmaf_percent}, %{port: :none} = state) do
    Logger.info("CrfSearch: Retrying with standard range for video #{video.id}")
    start_crf_search(video, vmaf_percent, {8, 40}, state)
  end

  def handle_cast({:crf_search, video, _vmaf_percent}, state) do
    Logger.error("CRF search already in progress for video #{video.id}")

    {:noreply, state}
  end

  def handle_cast({:crf_search_retry, video, _vmaf_percent}, state) do
    Logger.error("CRF search retry already in progress for video #{video.id}")

    {:noreply, state}
  end

  defp start_crf_search(video, vmaf_percent, crf_range, state) do
    args = build_crf_search_args(video, vmaf_percent, crf_range: crf_range)

    case Helper.open_port(args) do
      {:ok, port} ->
        # Extract OS PID immediately for process group tracking
        os_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, pid} -> pid
            _ -> nil
          end

        # Mark video as crf_searching ONLY AFTER successful port open
        case Media.mark_as_crf_searching(video) do
          {:ok, _updated_video} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Failed to mark video #{video.id} as crf_searching: #{inspect(reason)}"
            )
        end

        new_state = %{
          state
          | port: port,
            current_task: %{
              video: video,
              args: args,
              target_vmaf: vmaf_percent,
              crf_range: crf_range
            },
            output_buffer: [],
            os_pid: os_pid
        }

        # Dashboard event with enhanced metadata
        Events.broadcast_event(:crf_search_started, %{
          video_id: video.id,
          filename: Path.basename(video.path),
          target_vmaf: vmaf_percent,
          video_size: video.size,
          width: video.width,
          height: video.height,
          hdr: video.hdr,
          video_codecs: video.video_codecs,
          audio_codecs: video.audio_codecs,
          bitrate: video.bitrate
        })

        {:noreply, new_state}

      {:error, :not_found} ->
        Logger.error(
          "Failed to start CRF search for video #{video.id}: ab-av1 executable not found"
        )

        # Record failure
        Media.record_video_failure(video, :crf_search, :command_error,
          code: "executable_not_found",
          message: "ab-av1 executable not found on PATH",
          context: %{
            command: "ab-av1 #{Enum.join(args, " ")}",
            full_output: "ab-av1 executable not found"
          }
        )

        # Keep port as :none so GenServer stays available
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:test_reset, state) do
    # Test-only handler to force reset the GenServer state
    # This ensures clean state between tests
    if Application.get_env(:reencodarr, :environment) == :test do
      # Close any open port
      Retry.safe_port_close(state.port)

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

    # Wrap in try/rescue to prevent crashes from bad data or DB errors
    try do
      Retry.retry_on_db_busy(fn -> process_line(full_line, video, args, target_vmaf) end)

      new_output_buffer = [full_line | output_buffer]
      {:noreply, %{state | partial_line_buffer: "", output_buffer: new_output_buffer}}
    rescue
      e ->
        Logger.error("CrfSearch: Error processing line '#{full_line}': #{Exception.message(e)}")

        # Continue with original state, just clearing the buffer
        {:noreply, %{state | partial_line_buffer: "", output_buffer: [full_line | output_buffer]}}
    end
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
    Logger.info("✅ AbAv1: CRF search completed for video #{video.id}")

    # Wrap in try/rescue to ensure cleanup always happens
    try do
      # CRITICAL: Update video state to crf_searched to prevent infinite loop
      # Use retry logic for DB busy errors, but record failure if it still fails
      case Retry.retry_on_db_busy(fn -> Media.mark_as_crf_searched(video) end) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.error("Failed to mark video #{video.id} as crf_searched: #{inspect(reason)}")

          Media.record_video_failure(video, :crf_search, :database_error,
            code: "state_transition_failed",
            message: "Failed to mark video as crf_searched: #{inspect(reason)}",
            context: %{
              error: inspect(reason),
              video_id: video.id
            }
          )
      end
    rescue
      e ->
        Logger.error("CrfSearch: Error in exit_status=0 handler: #{Exception.message(e)}")
    end

    perform_crf_search_cleanup(state)
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

    # Wrap in try/rescue to ensure cleanup happens
    try do
      # Capture the full command output for failure analysis
      full_output = output_buffer |> Enum.reverse() |> Enum.join("\n")
      command_line = "ab-av1 " <> Enum.join(args, " ")

      handle_crf_search_failure(video, target_vmaf, exit_code, command_line, full_output, state)
    rescue
      e ->
        Logger.error("CrfSearch: Error in exit_status handler: #{Exception.message(e)}")
        # Still perform cleanup
        perform_crf_search_cleanup(state)
    end
  end

  # Handle port death without exit_status (safety net)
  @impl true
  def handle_info({:EXIT, port, reason}, %{port: port, current_task: %{video: video}} = state)
      when port != :none do
    Logger.error("CrfSearch: Port died unexpectedly: #{inspect(reason)}")

    # Record failure
    Media.record_video_failure(video, :crf_search, :command_error,
      code: "port_died",
      message: "Port died unexpectedly: #{inspect(reason)}",
      context: %{reason: inspect(reason)}
    )

    # Broadcast completion event
    Events.broadcast_event(:crf_search_completed, %{
      video_id: video.id,
      result: {:error, :port_died}
    })

    # Clean up and reset state
    {:noreply, %{state | port: :none, current_task: :none, partial_line_buffer: "", os_pid: nil}}
  end

  # Ignore EXIT from unknown ports (stale references after restart)
  @impl true
  def handle_info({:EXIT, _port, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:scanning_update, status, data}, state) do
    case status do
      :progress ->
        Logger.debug("Received vmaf search progress")
        maybe_upsert_vmaf_with_video(data)

      :finished ->
        maybe_upsert_vmaf_with_video(data)

      :failed ->
        Logger.error("Scanning failed: #{data}")
    end

    {:noreply, state}
  end

  defp maybe_upsert_vmaf_with_video(data) do
    service_id = data["service_id"] || data[:service_id]
    service_type = data["service_type"] || data[:service_type]
    path = data["path"] || data[:path]

    video =
      if service_id && service_type do
        case Media.get_video_by_service_id(service_id, service_type) do
          {:ok, video} -> video
          {:error, _} -> nil
        end
      else
        nil
      end

    if video do
      Media.upsert_vmaf(Map.put(data, "video_id", video.id))
    else
      Logger.error(
        "No video found for service_id=#{inspect(service_id)} service_type=#{inspect(service_type)} path=#{inspect(path)}, skipping VMAF insert"
      )
    end
  end

  defp handle_crf_search_failure(video, target_vmaf, exit_code, command_line, full_output, state) do
    crf_range = get_in(state, [:current_task, :crf_range]) || {8, 40}
    output_lines = state.output_buffer

    failure_context = %{
      exit_code: exit_code,
      command: command_line,
      full_output: full_output,
      target_vmaf: target_vmaf,
      crf_range: inspect(crf_range)
    }

    case retry_strategy(video, target_vmaf, crf_range, output_lines) do
      {:retry_wider_range} ->
        retry_crf_search(video, target_vmaf, state, failure_context,
          reason: "narrowed range #{inspect(crf_range)} failed"
        )

      {:retry_lower_target, new_target} ->
        retry_crf_search(video, new_target, state, failure_context,
          reason: "reducing VMAF target from #{target_vmaf} to #{new_target}"
        )

      :final_failure ->
        record_final_failure(video, target_vmaf, exit_code, full_output, failure_context, state)
    end
  end

  # Retry cascade: narrowed range → standard range → reduced target → fail
  defp retry_strategy(video, target_vmaf, crf_range, output_lines) do
    cond do
      CrfSearchHints.narrowed_range?(crf_range) ->
        {:retry_wider_range}

      crf_optimization_error?(output_lines) and target_vmaf >= Reencodarr.Rules.vmaf_target(video) ->
        {:retry_lower_target, target_vmaf - 1}

      true ->
        :final_failure
    end
  end

  defp retry_crf_search(video, new_target, state, failure_context, opts) do
    reason = Keyword.fetch!(opts, :reason)

    Logger.info("CrfSearch: Retrying video #{video.id} — #{reason}")

    Reencodarr.FailureTracker.record_vmaf_calculation_failure(
      video,
      "CRF search failed (#{reason}, will retry)",
      context: Map.put(failure_context, :final_failure, false)
    )

    Media.mark_as_analyzed(video)
    {:noreply, clean_state} = perform_crf_search_cleanup(state)
    GenServer.cast(__MODULE__, {:crf_search_retry, video, new_target})
    {:noreply, clean_state}
  end

  defp record_final_failure(video, target_vmaf, exit_code, _full_output, failure_context, state) do
    tested_scores = get_vmaf_scores_for_video(video.id)
    error_msg = build_detailed_error_message(target_vmaf, tested_scores, video.path)
    Logger.error(error_msg)

    # Record CRF optimization failure if that's what happened, otherwise generic
    if crf_optimization_error?(state.output_buffer) do
      Reencodarr.FailureTracker.record_crf_optimization_failure(
        video,
        target_vmaf,
        tested_scores,
        context: Map.put(failure_context, :final_failure, true)
      )
    else
      Reencodarr.FailureTracker.record_vmaf_calculation_failure(
        video,
        "Process failed with exit code #{exit_code}",
        context: Map.put(failure_context, :final_failure, true)
      )
    end

    # Ensure video is marked failed even if failure recording above had issues
    Media.mark_as_failed(video)

    perform_crf_search_cleanup(state)
  end

  @impl true
  def handle_call(:running?, _from, %{port: port} = state) do
    status = if port == :none, do: :not_running, else: :running
    {:reply, status, state}
  end

  @impl true
  def handle_call(:available?, _from, %{port: port} = state) do
    available = port == :none
    {:reply, available, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    debug_state = %{
      port_status: if(state.port == :none, do: :available, else: :busy),
      has_current_task: state.current_task != :none,
      current_task_video_id:
        if(state.current_task != :none, do: state.current_task.video.id, else: nil),
      os_pid: state.os_pid
    }

    {:reply, debug_state, state}
  end

  @impl true
  def handle_call(:reset_if_stuck, _from, state) do
    Logger.warning("Force resetting CRF searcher state - was stuck")

    # Kill the process group to ensure all children are killed
    Helper.kill_process_group(state.os_pid)

    # Close any open port
    Retry.safe_port_close(state.port)

    # Reset video state if we have one
    reset_video_state_if_present(state)

    # Reset to clean state
    clean_state = %{
      port: :none,
      current_task: :none,
      partial_line_buffer: "",
      output_buffer: [],
      os_pid: nil
    }

    # With new simple Broadway design, no need to notify - it polls automatically

    {:reply, :ok, clean_state}
  end

  # Private helper functions

  defp reset_video_state_if_present(%{current_task: :none}), do: :ok

  defp reset_video_state_if_present(%{current_task: %{video: video}}) do
    if is_struct(video, Reencodarr.Media.Video) do
      case Media.mark_as_analyzed(video) do
        {:ok, _} ->
          Logger.info("Reset video #{video.id} to analyzed state")

        {:error, reason} ->
          Logger.error("Failed to reset video #{video.id}: #{inspect(reason)}")
      end
    end
  end

  # Cleanup after CRF search when a video task was active - broadcasts completion event
  defp perform_crf_search_cleanup(%{current_task: %{video: video}} = state) do
    # Clean up persistent_term entry for progress debouncing
    filename = Path.basename(video.path)
    cache_key = {:crf_progress, filename}

    Retry.safe_persistent_term_erase(cache_key)

    # Broadcast completion event via unified Events system
    Events.broadcast_event(:crf_search_completed, %{
      video_id: video.id,
      result: :ok
    })

    new_state = %{
      state
      | port: :none,
        current_task: :none,
        partial_line_buffer: "",
        os_pid: nil
    }

    {:noreply, new_state}
  end

  # Cleanup after CRF search when no video task was active - just reset state
  defp perform_crf_search_cleanup(state) do
    # No current task, just reset state
    new_state = %{
      state
      | port: :none,
        current_task: :none,
        partial_line_buffer: "",
        os_pid: nil
    }

    {:noreply, new_state}
  end

  def process_line(line, video, args, target_vmaf \\ 95) do
    handlers = [
      &handle_encoding_sample_line/2,
      fn l, v -> handle_eta_vmaf_line(l, v, args) end,
      fn l, v -> handle_vmaf_line(l, v, args) end,
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
    case parse_line_with_types(line) do
      {:ok, %{type: :encoding_sample, data: sample_data}} ->
        Logger.debug(
          "CrfSearch: Encoding sample #{sample_data.sample_num}/#{sample_data.total_samples}: #{sample_data.crf}"
        )

        broadcast_crf_search_encoding_sample(video.path, %{
          video_id: video.id,
          filename: video.path,
          crf: sample_data.crf,
          sample_num: sample_data.sample_num,
          total_samples: sample_data.total_samples
        })

        true

      _ ->
        false
    end
  end

  defp handle_vmaf_line(line, video, args) do
    case parse_line_with_types(line) do
      {:ok, %{type: type, data: vmaf_data}}
      when type in [:vmaf_result, :sample_vmaf, :dash_vmaf] ->
        Logger.debug(
          "CrfSearch: CRF: #{vmaf_data.crf}, VMAF: #{vmaf_data.vmaf_score}, Percent: #{vmaf_data.percent}%"
        )

        upsert_vmaf_with_parsed_data(vmaf_data, false, video, args)
        true

      _ ->
        false
    end
  end

  # Remove unused try_patterns function since we're using parse_line_with_types

  defp handle_eta_vmaf_line(line, video, args) do
    case parse_line_with_types(line) do
      {:ok, %{type: :eta_vmaf, data: eta_data}} ->
        Logger.debug(
          "CrfSearch: CRF: #{eta_data.crf}, VMAF: #{eta_data.vmaf_score}, size: #{eta_data.predicted_size} #{eta_data.size_unit}, Percent: #{eta_data.percent}%, time: #{eta_data.time_taken} #{eta_data.time_unit}"
        )

        # Always insert the VMAF record, but log a warning if size exceeds 10GB
        estimated_size_bytes =
          Formatters.size_to_bytes(eta_data.predicted_size, eta_data.size_unit)

        # 10GB in bytes
        max_size_bytes = 10 * 1024 * 1024 * 1024

        if estimated_size_bytes && estimated_size_bytes > max_size_bytes do
          Logger.warning(
            "CrfSearch: VMAF CRF #{round(eta_data.crf)} estimated file size (#{Reencodarr.Formatters.size_gb(estimated_size_bytes)}) exceeds 10GB limit"
          )
        end

        upsert_vmaf_with_parsed_data(eta_data, true, video, args)
        true

      _ ->
        false
    end
  end

  defp handle_vmaf_comparison_line(line) do
    case parse_line_with_types(line) do
      {:ok, %{type: :vmaf_comparison, data: comparison_data}} ->
        Logger.debug("VMAF comparison: #{comparison_data.file1} vs #{comparison_data.file2}")
        true

      _ ->
        false
    end
  end

  defp handle_progress_line(line, video) do
    case parse_line_with_types(line) do
      {:ok, %{type: :progress, data: progress_data}} ->
        Logger.debug(
          "CrfSearch Progress: #{progress_data.progress}, FPS: #{progress_data.fps}, ETA: #{progress_data.eta}"
        )

        broadcast_crf_search_progress(video.path, %{
          video_id: video.id,
          filename: video.path,
          # Already numeric, no conversion needed
          percent: progress_data.progress,
          eta: progress_data.eta,
          # Already numeric, no conversion needed
          fps: progress_data.fps
        })

        true

      _ ->
        false
    end
  end

  defp handle_success_line(line, video) do
    case parse_line_with_types(line) do
      {:ok, %{type: :success, data: success_data}} ->
        Logger.debug("CrfSearch successful for CRF: #{success_data.crf}")

        # Mark VMAF as chosen first
        Media.mark_vmaf_as_chosen(video.id, success_data.crf)

        # Check if the chosen VMAF has a file size estimate that exceeds 10GB
        case get_vmaf_by_crf(video.id, success_data.crf) do
          nil ->
            Logger.warning(
              "CrfSearch: Could not find VMAF record for chosen CRF #{success_data.crf} for video #{video.id}"
            )

          vmaf ->
            handle_vmaf_size_check(vmaf, video, success_data.crf)
        end

        true

      _ ->
        false
    end
  end

  defp handle_warning_line(line, _video) do
    case parse_line_with_types(line) do
      {:ok, %{type: :warning, data: _warning_data}} ->
        # Log the warning at info level so tests can capture it
        Logger.info("CrfSearch: #{line}")
        true

      _ ->
        false
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
  end

  @crf_error_line "Error: Failed to find a suitable crf"

  defp handle_error_line(line, video, _target_vmaf) do
    if line == @crf_error_line do
      Logger.info("CrfSearch: CRF optimization error detected for video #{video.id}")
      # Don't record failure or mark as failed here — the exit handler
      # decides whether to retry with a reduced target or record final failure.
      true
    else
      false
    end
  end

  defp crf_optimization_error?(output_buffer) do
    Enum.any?(output_buffer, &(&1 == @crf_error_line))
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

        "#{base_msg}. Only #{length(scores)} VMAF score(s) were tested (highest: #{Reencodarr.Formatters.vmaf_score(max_score, 2)}). The search space may be too limited - try using a wider CRF range or different encoder settings."

      scores ->
        max_score = scores |> Enum.map(fn %{score: score} -> score end) |> Enum.max()
        min_score = scores |> Enum.map(fn %{score: score} -> score end) |> Enum.min()
        score_count = length(scores)

        if max_score < target_vmaf do
          gap = target_vmaf - max_score

          "#{base_msg}. Tested #{score_count} CRF values with VMAF scores ranging from #{Reencodarr.Formatters.vmaf_score(min_score, 2)} to #{Reencodarr.Formatters.vmaf_score(max_score, 2)}. The highest quality (#{Reencodarr.Formatters.vmaf_score(max_score, 2)}) is still #{Reencodarr.Formatters.vmaf_score(gap, 2)} points below the target. Try lowering the target VMAF or using a higher quality encoder preset."
        else
          "#{base_msg}. Tested #{score_count} CRF values with VMAF scores ranging from #{Reencodarr.Formatters.vmaf_score(min_score, 2)} to #{Reencodarr.Formatters.vmaf_score(max_score, 2)}. The search algorithm couldn't converge on a suitable CRF value - this may indicate an issue with the binary search algorithm or encoder settings."
        end
    end
  end

  def build_crf_search_args(video, vmaf_percent, opts \\ []) do
    {min_crf, max_crf} = Keyword.get(opts, :crf_range, {8, 40})

    base_args = [
      "crf-search",
      "--input",
      video.path,
      "--min-vmaf",
      Integer.to_string(vmaf_percent),
      "--min-crf",
      to_string(min_crf),
      "--max-crf",
      to_string(max_crf),
      "--temp-dir",
      Helper.temp_dir()
    ]

    # Use centralized Rules module to handle all argument building and deduplication
    Reencodarr.Rules.build_args(video, :crf_search, [], base_args)
  end

  # New function that accepts pre-parsed data instead of string parameters
  defp upsert_vmaf_with_parsed_data(vmaf_data, chosen, video, args) do
    vmaf_params = %{
      "crf" => vmaf_data.crf,
      # Map vmaf_score to score field expected by schema
      "score" => vmaf_data.vmaf_score,
      "percent" => vmaf_data.percent,
      "chosen" => chosen
    }

    # Handle time data if present (from eta_vmaf patterns)
    vmaf_params =
      if Map.has_key?(vmaf_data, :time_taken) and Map.has_key?(vmaf_data, :time_unit) do
        time_seconds = Time.to_seconds(vmaf_data.time_taken, vmaf_data.time_unit)
        # Round to integer for database
        Map.put(vmaf_params, "time", round(time_seconds))
      else
        Map.put(vmaf_params, "time", nil)
      end

    # Handle size data if present
    size_info =
      if Map.has_key?(vmaf_data, :predicted_size) and Map.has_key?(vmaf_data, :size_unit) do
        # Format size as integer if it's a whole number, otherwise as float
        formatted_size =
          if vmaf_data.predicted_size == Float.round(vmaf_data.predicted_size) do
            "#{round(vmaf_data.predicted_size)} #{vmaf_data.size_unit}"
          else
            "#{vmaf_data.predicted_size} #{vmaf_data.size_unit}"
          end

        formatted_size
      else
        nil
      end

    # Calculate savings based on percent and video size - no parsing needed since percent is already numeric!
    savings = calculate_savings_from_numeric(vmaf_data.percent, video.size)

    final_vmaf_data =
      Map.merge(vmaf_params, %{
        "video_id" => video.id,
        "params" => Helper.remove_args(args, ["--min-vmaf", "crf-search"]),
        "size" => size_info,
        "savings" => savings,
        "target" => 95
      })

    case Media.upsert_vmaf(final_vmaf_data) do
      {:ok, created_vmaf} ->
        Logger.debug("Upserted VMAF: #{inspect(created_vmaf)}")
        broadcast_crf_search_vmaf_result(video.path, created_vmaf)
        created_vmaf

      {:error, changeset} ->
        Logger.error("Failed to upsert VMAF: #{inspect(changeset)}")
        nil
    end
  end

  # Removed old upsert_vmaf function - replaced with upsert_vmaf_with_parsed_data

  defp broadcast_crf_search_progress(video_path, progress_data) do
    filename = Path.basename(video_path)

    progress =
      case progress_data do
        %{} = existing_progress ->
          # Update filename to ensure it's consistent and preserve video_id
          %{existing_progress | filename: filename}

        vmaf when is_map(vmaf) ->
          # Convert VMAF struct to CrfSearchProgress
          crf_value = convert_to_number(vmaf.crf)
          score_value = convert_to_number(vmaf.score)
          percent_value = convert_to_number(vmaf.percent)

          Logger.debug(
            "CrfSearch: Converting VMAF to progress - CRF: #{inspect(crf_value)}, Score: #{inspect(score_value)}, Percent: #{inspect(percent_value)}"
          )

          # Include all fields for progress tracking
          %{
            video_id: progress_data[:video_id],
            filename: filename,
            percent: percent_value,
            crf: crf_value,
            score: score_value
          }

        invalid_data ->
          Logger.warning("CrfSearch: Invalid progress data received: #{inspect(invalid_data)}")
          %{video_id: progress_data[:video_id], filename: filename}
      end

    # Debounce telemetry updates to avoid overwhelming the dashboard
    if should_emit_progress?(filename, progress) do
      # Clean dashboard event
      Events.broadcast_event(:crf_search_progress, %{
        video_id: progress[:video_id],
        percent: progress[:percent] || 0,
        filename: progress[:filename] && Path.basename(progress[:filename])
      })

      # Update cache
      update_last_progress(filename, progress)
    end
  end

  defp broadcast_crf_search_encoding_sample(_video_path, sample_data) do
    Events.broadcast_event(:crf_search_encoding_sample, %{
      video_id: sample_data[:video_id],
      filename: sample_data[:filename] && Path.basename(sample_data[:filename]),
      crf: sample_data[:crf],
      sample_num: sample_data[:sample_num],
      total_samples: sample_data[:total_samples]
    })
  end

  defp broadcast_crf_search_vmaf_result(video_path, vmaf_data) do
    Events.broadcast_event(:crf_search_vmaf_result, %{
      video_id: vmaf_data.video_id,
      filename: video_path && Path.basename(video_path),
      crf: vmaf_data.crf,
      score: vmaf_data.score,
      percent: vmaf_data.percent
    })
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

  defp convert_to_number(nil), do: nil
  defp convert_to_number(val) when is_number(val), do: val

  defp convert_to_number(val) when is_binary(val) do
    Parsers.parse_float(val)
  end

  defp convert_to_number(_), do: nil

  # Get VMAF record by video ID and CRF value
  defp get_vmaf_by_crf(video_id, crf_value) when is_number(crf_value) do
    import Ecto.Query

    query =
      from v in Media.Vmaf,
        where: v.video_id == ^video_id and v.crf == ^crf_value,
        limit: 1

    Repo.one(query)
  end

  defp get_vmaf_by_crf(video_id, crf_str) when is_binary(crf_str) do
    case Parsers.parse_float_exact(crf_str) do
      {:ok, crf_float} ->
        import Ecto.Query

        query =
          from v in Media.Vmaf,
            where: v.video_id == ^video_id and v.crf == ^crf_float,
            limit: 1

        Repo.one(query)

      {:error, _} ->
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
    estimated_size_bytes = Formatters.size_to_bytes(size_value, unit)
    # 10GB in bytes
    max_size_bytes = 10 * 1024 * 1024 * 1024

    if estimated_size_bytes && estimated_size_bytes > max_size_bytes do
      Logger.info(
        "CrfSearch: VMAF estimated size #{Reencodarr.Formatters.size_gb(estimated_size_bytes, 2)} exceeds 10GB limit for video #{video.id}"
      )

      {:error, :size_too_large}
    else
      :ok
    end
  end

  # Removed old parse_time function - no longer needed since we parse time data early with proper types

  # Calculate estimated space savings in bytes based on percent and video size
  defp calculate_savings(nil, _video_size), do: nil
  defp calculate_savings(_percent, nil), do: nil

  defp calculate_savings(percent, video_size) when is_binary(percent) do
    case Parsers.parse_float_exact(percent) do
      {:ok, percent_float} -> calculate_savings(percent_float, video_size)
      {:error, _} -> nil
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

  # New function for pre-parsed numeric data (no late parsing!) - just delegates to the existing function
  defp calculate_savings_from_numeric(percent, video_size),
    do: calculate_savings(percent, video_size)
end
