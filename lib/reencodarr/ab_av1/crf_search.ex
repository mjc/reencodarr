defmodule Reencodarr.AbAv1.CrfSearch do
  @moduledoc """
  GenServer for handling CRF search operations using ab-av1.

  This module manages CRF search business logic (VMAF parsing, DB updates,
  retry strategy) but does NOT own the OS port. Port ownership is held by
  `AbAv1.CrfSearcher`, which survives restarts of this GenServer. On restart,
  `init/1` re-subscribes to `CrfSearcher` and recovers state from its metadata.
  """

  use GenServer

  import Ecto.Query

  alias Reencodarr.AbAv1.CrfSearcher
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

  defp parse_line_with_types(line) do
    OutputParser.parse_line(line)
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec crf_search(map(), integer()) :: :ok | :error
  def crf_search(video, _vmaf_percent) when is_nil(video.id), do: :error

  def crf_search(video, _vmaf_percent) when video.state == :encoded do
    Logger.info("Skipping crf search for video #{video.path} as it is already encoded")

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
    case GenServer.whereis(__MODULE__) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  @spec available?() :: :available | :busy | :timeout
  def available? do
    case GenServer.whereis(__MODULE__) do
      nil ->
        :timeout

      pid when is_pid(pid) ->
        try do
          case GenServer.call(pid, :available?, 1000) do
            true -> :available
            false -> :busy
          end
        catch
          :exit, _ -> :timeout
        end
    end
  end

  def get_state do
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
    case GenServer.whereis(__MODULE__) do
      nil ->
        {:error, :not_running}

      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, :reset_if_stuck, 5_000)
        catch
          :exit, _ -> {:error, :timeout}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)
    {:ok, recover_or_init_state()}
  end

  @impl true
  def terminate(reason, state) when reason in [:normal, :shutdown] do
    Logger.warning("CrfSearch GenServer terminating: #{inspect(reason)}")
    reset_video_on_terminate(state)
    :ok
  end

  # Crash — leave CrfSearcher running so the port survives; init will re-subscribe
  def terminate(reason, state) do
    Logger.warning("CrfSearch GenServer terminating (crash): #{inspect(reason)}")
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
  def handle_cast({:crf_search, video, vmaf_percent}, %{current_task: :none} = state) do
    crf_range = CrfSearchHints.crf_range(video, vmaf_percent)
    start_crf_search(video, vmaf_percent, crf_range, state)
  end

  def handle_cast({:crf_search_retry, video, vmaf_percent}, %{current_task: :none} = state) do
    Logger.info("CrfSearch: Retrying with standard range for video #{video.id}")
    crf_range = CrfSearchHints.crf_range(video, vmaf_percent, retry: true)
    start_crf_search(video, vmaf_percent, crf_range, state)
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
    metadata = %{video: video, args: args, target_vmaf: vmaf_percent, crf_range: crf_range}

    case CrfSearcher.start(args, metadata) do
      {:ok, searcher_pid} ->
        monitor = Process.monitor(searcher_pid)
        {:ok, _} = CrfSearcher.subscribe(self())
        os_pid = CrfSearcher.get_os_pid()

        # Mark video as crf_searching AFTER successful port open
        video =
          case Media.mark_as_crf_searching(video) do
            {:ok, updated_video} ->
              updated_video

            {:error, reason} ->
              Logger.warning(
                "Failed to mark video #{video.id} as crf_searching: #{inspect(reason)}"
              )

              video
          end

        new_state = %{
          state
          | current_task: %{
              video: video,
              args: args,
              target_vmaf: vmaf_percent,
              crf_range: crf_range
            },
            output_buffer: [],
            searcher_monitor: monitor,
            os_pid: os_pid
        }

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

      {:error, reason} ->
        Logger.error("Failed to start CRF search for video #{video.id}: #{inspect(reason)}")

        Media.record_video_failure(video, :crf_search, :command_error,
          code: "start_failed",
          message: "Failed to start CrfSearcher: #{inspect(reason)}",
          context: %{
            command: "ab-av1 #{Enum.join(args, " ")}",
            full_output: inspect(reason)
          }
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:test_reset, state) do
    if Application.get_env(:reencodarr, :environment) == :test do
      if state.searcher_monitor, do: Process.demonitor(state.searcher_monitor, [:flush])
      CrfSearcher.kill()

      {:noreply,
       %{
         current_task: :none,
         partial_line_buffer: "",
         output_buffer: [],
         searcher_monitor: nil,
         os_pid: nil
       }}
    else
      {:noreply, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Port output forwarded from CrfSearcher
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(
        {CrfSearcher, {:line, line}},
        %{
          current_task: %{video: video, args: args, target_vmaf: target_vmaf},
          partial_line_buffer: buffer,
          output_buffer: output_buffer
        } = state
      ) do
    full_line = buffer <> line

    try do
      Retry.retry_on_db_busy(fn -> process_line(full_line, video, args, target_vmaf) end)
      new_output_buffer = [full_line | output_buffer]
      {:noreply, %{state | partial_line_buffer: "", output_buffer: new_output_buffer}}
    rescue
      e ->
        Logger.error("CrfSearch: Error processing line '#{full_line}': #{Exception.message(e)}")
        {:noreply, %{state | partial_line_buffer: "", output_buffer: [full_line | output_buffer]}}
    end
  end

  @impl true
  def handle_info(
        {CrfSearcher, {:partial, chunk}},
        %{current_task: %{video: video}, partial_line_buffer: buffer} = state
      ) do
    Logger.debug("Received partial data chunk for video #{video.id}, buffering.")
    {:noreply, %{state | partial_line_buffer: buffer <> chunk}}
  end

  # Success exit
  @impl true
  def handle_info(
        {CrfSearcher, {:exit_status, 0}},
        %{current_task: %{video: video}} = state
      ) do
    Logger.info("AbAv1: CRF search completed for video #{video.id}")

    try do
      if Media.vmaf_records_exist?(video) do
        ensure_chosen_vmaf_and_transition(video)
      else
        Logger.error(
          "CRF search completed for video #{video.id} but no VMAF records were created"
        )

        Media.record_video_failure(video, :crf_search, :validation,
          code: "no_vmaf_results",
          message: "CRF search process completed but produced no VMAF results",
          context: %{
            video_id: video.id,
            note: "Process exited with status 0 but no output lines were parsed into VMAF records"
          }
        )

        Media.mark_as_failed(video)
      end
    rescue
      e ->
        Logger.error("CrfSearch: Error in exit_status=0 handler: #{Exception.message(e)}")
    end

    perform_crf_search_cleanup(state)
  end

  # Failure exit
  @impl true
  def handle_info(
        {CrfSearcher, {:exit_status, exit_code}},
        %{
          current_task: %{video: video, args: args, target_vmaf: target_vmaf},
          output_buffer: output_buffer
        } = state
      )
      when exit_code != 0 do
    Logger.error("CRF search failed for video #{video.id} with exit code #{exit_code}")

    try do
      full_output = output_buffer |> Enum.reverse() |> Enum.join("\n")
      command_line = "ab-av1 " <> Enum.join(args, " ")
      handle_crf_search_failure(video, target_vmaf, exit_code, command_line, full_output, state)
    rescue
      e ->
        Logger.error("CrfSearch: Error in exit_status handler: #{Exception.message(e)}")
        perform_crf_search_cleanup(state)
    end
  end

  # CrfSearcher process died unexpectedly while task was active
  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{searcher_monitor: ref, current_task: %{video: video}} = state
      ) do
    Logger.error("CrfSearch: CrfSearcher process went down: #{inspect(reason)}")

    Media.record_video_failure(video, :crf_search, :command_error,
      code: "searcher_died",
      message: "CrfSearcher process died: #{inspect(reason)}",
      context: %{reason: inspect(reason)}
    )

    Events.broadcast_event(:crf_search_completed, %{
      video_id: video.id,
      result: {:error, :searcher_died}
    })

    {:noreply,
     %{
       state
       | current_task: :none,
         partial_line_buffer: "",
         output_buffer: [],
         searcher_monitor: nil,
         os_pid: nil
     }}
  end

  # Stale or irrelevant :DOWN
  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  # Stale CrfSearcher messages after reset
  @impl true
  def handle_info({CrfSearcher, _msg}, state) do
    {:noreply, state}
  end

  # Ignore EXIT signals (trap_exit set but we don't own ports)
  @impl true
  def handle_info({:EXIT, _from, _reason}, state) do
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

  @impl true
  def handle_info(msg, state) do
    Logger.warning("CrfSearch: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:available?, _from, state) do
    {:reply, state.current_task == :none, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    debug_state = %{
      port_status: if(state.current_task == :none, do: :available, else: :busy),
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

    # Demonitor first to flush any pending :DOWN message
    if state.searcher_monitor, do: Process.demonitor(state.searcher_monitor, [:flush])

    # Kill CrfSearcher (kills OS process group then stops GenServer)
    CrfSearcher.kill()

    # Reset video state if we have one
    reset_video_state_if_present(state)

    clean_state = %{
      current_task: :none,
      partial_line_buffer: "",
      output_buffer: [],
      searcher_monitor: nil,
      os_pid: nil
    }

    {:reply, :ok, clean_state}
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  # Ensures a chosen VMAF exists before transitioning to crf_searched.
  # If no VMAF is marked chosen (e.g. success line wasn't parsed or
  # mark_vmaf_as_chosen failed), auto-selects the best candidate.
  defp ensure_chosen_vmaf_and_transition(video) do
    if !Media.chosen_vmaf_exists?(video) do
      Logger.warning("No chosen VMAF for video #{video.id}, auto-selecting best candidate")

      case Media.choose_best_vmaf(video) do
        {:ok, vmaf} ->
          Logger.info("Auto-chose VMAF CRF=#{vmaf.crf} score=#{vmaf.score} for video #{video.id}")

        {:error, reason} ->
          Logger.error("Failed to auto-choose VMAF for video #{video.id}: #{inspect(reason)}")
      end
    end

    case Retry.retry_on_db_busy(fn -> Media.mark_as_crf_searched(video) end) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to mark video #{video.id} as crf_searched: #{inspect(reason)}")

        Media.record_video_failure(video, :crf_search, :validation,
          code: "state_transition_failed",
          message: "Failed to mark video as crf_searched: #{inspect(reason)}",
          context: %{error: inspect(reason), video_id: video.id}
        )
    end
  end

  defp recover_or_init_state do
    if CrfSearcher.running?() do
      case CrfSearcher.get_metadata() do
        {:ok, metadata} ->
          searcher_pid = Process.whereis(CrfSearcher)
          monitor = Process.monitor(searcher_pid)
          {:ok, _replayed} = CrfSearcher.subscribe(self())
          os_pid = CrfSearcher.get_os_pid()

          Logger.info(
            "CrfSearch: recovering — re-subscribed to CrfSearcher, video #{metadata.video.id}"
          )

          %{
            current_task: %{
              video: metadata.video,
              args: metadata.args,
              target_vmaf: metadata.target_vmaf,
              crf_range: metadata.crf_range
            },
            partial_line_buffer: "",
            output_buffer: [],
            searcher_monitor: monitor,
            os_pid: os_pid
          }

        _err ->
          empty_state_after_orphan_kill()
      end
    else
      empty_state_after_orphan_kill()
    end
  end

  defp empty_state_after_orphan_kill do
    empty_state()
  end

  defp empty_state do
    %{
      current_task: :none,
      partial_line_buffer: "",
      output_buffer: [],
      searcher_monitor: nil,
      os_pid: nil
    }
  end

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

  defp perform_crf_search_cleanup(%{current_task: %{video: video}} = state) do
    Events.broadcast_event(:crf_search_completed, %{
      video_id: video.id,
      result: :ok
    })

    if state.searcher_monitor, do: Process.demonitor(state.searcher_monitor, [:flush])

    new_state = %{
      state
      | current_task: :none,
        partial_line_buffer: "",
        output_buffer: [],
        searcher_monitor: nil,
        os_pid: nil
    }

    {:noreply, new_state}
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
    crf_range = get_in(state, [:current_task, :crf_range]) || {5, 70}
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

    Media.mark_as_failed(video)
    perform_crf_search_cleanup(state)
  end

  def process_line(line, video, args, target_vmaf) do
    handlers = [
      &handle_encoding_sample_line/2,
      fn l, v -> handle_eta_vmaf_line(l, v, args, target_vmaf) end,
      fn l, v -> handle_vmaf_line(l, v, args, target_vmaf) end,
      fn l, _v -> handle_vmaf_comparison_line(l) end,
      &handle_progress_line/2,
      &handle_success_line/2,
      &handle_warning_line/2,
      fn l, v -> handle_error_line(l, v) end
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

  defp handle_vmaf_line(line, video, args, target_vmaf) do
    case parse_line_with_types(line) do
      {:ok, %{type: type, data: vmaf_data}}
      when type in [:vmaf_result, :sample_vmaf, :dash_vmaf] ->
        Logger.debug(
          "CrfSearch: CRF: #{vmaf_data.crf}, VMAF: #{vmaf_data.vmaf_score}, Percent: #{vmaf_data.percent}%"
        )

        upsert_vmaf_with_parsed_data(vmaf_data, false, video, args, target_vmaf)
        true

      _ ->
        false
    end
  end

  defp handle_eta_vmaf_line(line, video, args, target_vmaf) do
    case parse_line_with_types(line) do
      {:ok, %{type: :eta_vmaf, data: eta_data}} ->
        Logger.debug(
          "CrfSearch: CRF: #{eta_data.crf}, VMAF: #{eta_data.vmaf_score}, size: #{eta_data.predicted_size} #{eta_data.size_unit}, Percent: #{eta_data.percent}%, time: #{eta_data.time_taken} #{eta_data.time_unit}"
        )

        estimated_size_bytes =
          Formatters.size_to_bytes(eta_data.predicted_size, eta_data.size_unit)

        max_size_bytes = 10 * 1024 * 1024 * 1024

        if estimated_size_bytes && estimated_size_bytes > max_size_bytes do
          Logger.warning(
            "CrfSearch: VMAF CRF #{round(eta_data.crf)} estimated file size (#{Reencodarr.Formatters.size_gb(estimated_size_bytes)}) exceeds 10GB limit"
          )
        end

        upsert_vmaf_with_parsed_data(eta_data, false, video, args, target_vmaf)
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
          percent: progress_data.progress,
          eta: progress_data.eta,
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

        case Media.mark_vmaf_as_chosen(video.id, success_data.crf) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "CrfSearch: mark_vmaf_as_chosen failed for CRF #{success_data.crf} video #{video.id}: #{inspect(reason)}"
            )
        end

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
        Logger.info("CrfSearch: #{line}")
        true

      _ ->
        false
    end
  end

  defp handle_vmaf_size_check(vmaf, video, crf) do
    case check_vmaf_size_limit(vmaf, video) do
      :ok -> :ok
      {:error, :size_too_large} -> handle_size_limit_exceeded(video, crf)
    end
  end

  defp handle_size_limit_exceeded(video, crf) do
    Logger.error(
      "CrfSearch: Chosen VMAF CRF #{crf} exceeds 10GB limit for video #{video.id}. Marking as failed."
    )

    Reencodarr.FailureTracker.record_size_limit_failure(video, "Estimated > 10GB", "10GB",
      context: %{chosen_crf: crf}
    )
  end

  @crf_error_line "Error: Failed to find a suitable crf"

  defp handle_error_line(line, video) do
    if line == @crf_error_line do
      Logger.info("CrfSearch: CRF optimization error detected for video #{video.id}")
      true
    else
      false
    end
  end

  defp crf_optimization_error?(output_buffer) do
    Enum.any?(output_buffer, &(&1 == @crf_error_line))
  end

  defp get_vmaf_scores_for_video(video_id) do
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
        Enum.map(vmaf_entries, fn %{crf: crf, score: score} -> %{crf: crf, score: score} end)
    end
  end

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
    {min_crf, max_crf} = Keyword.get(opts, :crf_range, {5, 70})

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

    Reencodarr.Rules.build_args(video, :crf_search, [], base_args)
  end

  defp upsert_vmaf_with_parsed_data(vmaf_data, chosen, video, args, target_vmaf) do
    vmaf_params = %{
      "crf" => vmaf_data.crf,
      "score" => vmaf_data.vmaf_score,
      "percent" => vmaf_data.percent,
      "chosen" => chosen
    }

    vmaf_params =
      if Map.has_key?(vmaf_data, :time_taken) and Map.has_key?(vmaf_data, :time_unit) do
        time_seconds = Time.to_seconds(vmaf_data.time_taken, vmaf_data.time_unit)
        Map.put(vmaf_params, "time", round(time_seconds))
      else
        Map.put(vmaf_params, "time", nil)
      end

    size_info =
      if Map.has_key?(vmaf_data, :predicted_size) and Map.has_key?(vmaf_data, :size_unit) do
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

    savings = calculate_savings(vmaf_data.percent, video.size)

    final_vmaf_data =
      Map.merge(vmaf_params, %{
        "video_id" => video.id,
        "params" => Helper.remove_args(args, ["--min-vmaf", "crf-search"]),
        "size" => size_info,
        "savings" => savings,
        "target" => target_vmaf
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

  defp broadcast_crf_search_progress(video_path, progress_data) do
    filename = Path.basename(video_path)

    Events.broadcast_event(:crf_search_progress, %{
      video_id: progress_data[:video_id],
      percent: progress_data[:percent] || 0,
      filename: filename
    })
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

  defp get_vmaf_by_crf(video_id, crf_value) when is_number(crf_value) do
    query =
      from v in Media.Vmaf,
        where: v.video_id == ^video_id and v.crf == ^crf_value,
        limit: 1

    Repo.one(query)
  end

  defp get_vmaf_by_crf(video_id, crf_str) when is_binary(crf_str) do
    case Parsers.parse_float_exact(crf_str) do
      {:ok, crf_float} ->
        query =
          from v in Media.Vmaf,
            where: v.video_id == ^video_id and v.crf == ^crf_float,
            limit: 1

        Repo.one(query)

      {:error, _} ->
        nil
    end
  end

  defp check_vmaf_size_limit(vmaf, video) do
    case vmaf.size do
      nil -> :ok
      size_str when is_binary(size_str) -> check_size_string_limit(size_str, video)
      _ -> :ok
    end
  end

  defp check_size_string_limit(size_str, video) do
    case Regex.run(~r/^(\d+\.?\d*)\s+(\w+)$/, String.trim(size_str)) do
      [_, size_value, unit] -> validate_size_limit(size_value, unit, video)
      _ -> :ok
    end
  end

  defp validate_size_limit(size_value, unit, video) do
    estimated_size_bytes = Formatters.size_to_bytes(size_value, unit)
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
      round((100 - percent) / 100 * video_size)
    else
      nil
    end
  end

  defp calculate_savings(_, _), do: nil
end
