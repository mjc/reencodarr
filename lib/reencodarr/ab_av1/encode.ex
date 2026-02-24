defmodule Reencodarr.AbAv1.Encode do
  @moduledoc """
  GenServer for handling video encoding operations using ab-av1.

  This module manages encoding business logic (progress parsing, DB updates,
  file operations) but does NOT own the OS port. Port ownership is held by
  `AbAv1.Encoder`, which survives restarts of this GenServer. On restart,
  `init/1` re-subscribes to `Encoder` and recovers state from its metadata.
  """

  use GenServer

  alias Reencodarr.AbAv1.Encoder
  alias Reencodarr.AbAv1.Helper
  alias Reencodarr.AbAv1.ProgressParser
  alias Reencodarr.Core.Retry
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Encoder.Broadway.Producer
  alias Reencodarr.{Media, PostProcessor}
  alias Reencodarr.Media.Vmaf

  require Logger

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec encode(Media.Vmaf.t()) :: :ok
  def encode(vmaf) do
    GenServer.cast(__MODULE__, {:encode, vmaf})
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

      pid ->
        try do
          case GenServer.call(pid, :available?, 100) do
            true -> :available
            false -> :busy
          end
        catch
          :exit, _ -> :timeout
        end
    end
  end

  @doc """
  Force reset the GenServer if it's stuck. Kills the port holder process,
  resets video state, and clears internal state.
  """
  @spec reset_if_stuck() :: :ok | {:error, :not_running}
  def reset_if_stuck do
    case GenServer.whereis(__MODULE__) do
      nil ->
        {:error, :not_running}

      pid ->
        try do
          GenServer.call(pid, :reset_if_stuck, 5_000)
        catch
          :exit, _ -> {:error, :timeout}
        end
    end
  end

  @doc "Get the current GenServer state for debugging."
  @spec get_state() :: map() | {:error, :not_running}
  def get_state do
    case GenServer.whereis(__MODULE__) do
      nil ->
        {:error, :not_running}

      pid ->
        try do
          GenServer.call(pid, :get_state, 1000)
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
    # Keep trap_exit so supervisor :shutdown flows through terminate/2
    Process.flag(:trap_exit, true)

    {:ok, recover_or_init_state()}
  end

  @impl true
  # Clean or supervised shutdown — best-effort: reset video so it can be re-queued
  def terminate(reason, state) when reason in [:normal, :shutdown] do
    Logger.warning("Encode GenServer terminating: #{inspect(reason)}")
    reset_video_if_present(state)
    :ok
  end

  # Crash — leave Encoder running so the port survives; init will re-subscribe
  def terminate(reason, state) do
    Logger.warning("Encode GenServer terminating (crash): #{inspect(reason)}")
    reset_video_if_present(state)
    :ok
  end

  @impl true
  def handle_call(:available?, _from, state) do
    {:reply, state.video == :none, state}
  end

  @impl true
  def handle_call(:running?, _from, state) do
    status = if state.video == :none, do: :not_running, else: :running
    {:reply, status, state}
  end

  @impl true
  def handle_call(:reset_if_stuck, _from, state) do
    Logger.warning("Force resetting Encode GenServer - was stuck")

    # Demonitor first to flush any pending :DOWN message
    if state.encoder_monitor, do: Process.demonitor(state.encoder_monitor, [:flush])

    # Kill Encoder (kills OS process group then stops GenServer)
    Encoder.kill()

    # Reset video state so it can be re-queued
    reset_video_if_present(state)

    # Notify Broadway producer
    Producer.dispatch_available()

    {:reply, :ok, clear_state(state)}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    debug_state = %{
      port_status: if(state.video == :none, do: :available, else: :busy),
      has_video: state.video != :none,
      video_id: if(state.video != :none, do: state.video.id, else: nil),
      os_pid: state.os_pid,
      output_lines_count: length(state.output_lines)
    }

    {:reply, debug_state, state}
  end

  @impl true
  def handle_cast(
        {:encode, %Vmaf{params: _params} = vmaf},
        %{video: :none} = state
      ) do
    new_state = prepare_encode_state(vmaf, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:encode, %Vmaf{} = _vmaf}, state) do
    Logger.info("Encoding is already in progress, skipping new encode request.")
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Port output forwarded from Encoder
  # ---------------------------------------------------------------------------

  # eol line — process it
  @impl true
  def handle_info(
        {Encoder, {:line, data}},
        %{partial_line_buffer: buffer, output_lines: output_lines} = state
      )
      when state.video != :none do
    full_line = buffer <> data

    try do
      ProgressParser.process_line(full_line, state)
      updated_state = extract_and_store_progress(full_line, state)

      new_output_lines =
        if length(output_lines) < 1024 do
          [full_line | output_lines]
        else
          [full_line | Enum.take(output_lines, 1023)]
        end

      {:noreply, %{updated_state | partial_line_buffer: "", output_lines: new_output_lines}}
    rescue
      e ->
        Logger.error(
          "AbAv1.Encode: Error processing line '#{full_line}': #{Exception.message(e)}"
        )

        {:noreply, %{state | partial_line_buffer: "", output_lines: [full_line | output_lines]}}
    end
  end

  # partial chunk — accumulate into buffer
  @impl true
  def handle_info({Encoder, {:partial, chunk}}, %{partial_line_buffer: buffer} = state)
      when state.video != :none do
    {:noreply, %{state | partial_line_buffer: buffer <> chunk}}
  end

  # port exited
  @impl true
  def handle_info(
        {Encoder, {:exit_status, exit_code}},
        %{
          vmaf: vmaf,
          output_file: output_file,
          encode_args: encode_args,
          output_lines: output_lines
        } = state
      )
      when state.video != :none do
    try do
      pubsub_result =
        if is_integer(exit_code) and exit_code == 0, do: :success, else: {:error, exit_code}

      Events.broadcast_event(:encoding_completed, %{
        video_id: vmaf.video.id,
        result: pubsub_result
      })

      Producer.dispatch_available()

      Retry.retry_on_db_busy(fn ->
        if is_integer(exit_code) and exit_code == 0 do
          notify_encoder_success(vmaf.video, output_file)
        else
          notify_encoder_failure(vmaf.video, exit_code, encode_args, output_lines)
        end
      end)
    rescue
      e ->
        Logger.error("AbAv1.Encode: Error in exit_status handler: #{Exception.message(e)}")
    end

    {:noreply, clear_state(state)}
  end

  # Stale Encoder messages after reset — ignore
  @impl true
  def handle_info({Encoder, _msg}, state) do
    {:noreply, state}
  end

  # Encoder process went down unexpectedly while an encode was in progress
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{encoder_monitor: ref} = state)
      when state.video != :none do
    Logger.error("AbAv1.Encode: Encoder process went down: #{inspect(reason)}")

    if state.vmaf != :none do
      Events.broadcast_event(:encoding_completed, %{
        video_id: state.vmaf.video.id,
        result: {:error, :encoder_died}
      })

      Producer.dispatch_available()
    end

    {:noreply, clear_state(state)}
  end

  # Stale or irrelevant :DOWN (after reset or mismatched monitor ref)
  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  # Periodic heartbeat — broadcast last known progress to keep dashboard alive
  @impl true
  def handle_info(:periodic_check, %{video: :none} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:periodic_check, %{video: video, last_progress: last_progress} = state)
      when video != :none do
    if last_progress do
      Events.broadcast_event(:encoding_progress, %{
        video_id: video.id,
        percent: last_progress.percent,
        fps: last_progress.fps,
        eta: last_progress.eta,
        filename: Path.basename(video.path)
      })

      Events.broadcast_event(:encoder_started, %{})
    end

    Process.send_after(self(), :periodic_check, 10_000)
    {:noreply, state}
  end

  # Ignore EXIT signals (we trap_exit but don't own ports)
  @impl true
  def handle_info({:EXIT, _from, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(message, state) do
    Logger.warning("AbAv1.Encode: Received unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  # On init, check if Encoder is already running (we crashed mid-encode).
  # If so, re-subscribe and recover state from its stored metadata.
  defp recover_or_init_state do
    if Encoder.running?() do
      case Encoder.get_metadata() do
        {:ok, metadata} ->
          encoder_pid = Process.whereis(Encoder)
          monitor = Process.monitor(encoder_pid)
          {:ok, _replayed} = Encoder.subscribe(self())
          os_pid = Encoder.get_os_pid()

          Logger.info(
            "Encode: recovering — re-subscribed to Encoder, video #{metadata.vmaf.video.id}"
          )

          Process.send_after(self(), :periodic_check, 10_000)

          %{
            video: metadata.vmaf.video,
            vmaf: metadata.vmaf,
            output_file: metadata.output_file,
            encode_args: metadata.encode_args,
            partial_line_buffer: "",
            last_progress: nil,
            output_lines: [],
            encoder_monitor: monitor,
            os_pid: os_pid
          }

        _err ->
          # Encoder running but metadata unavailable — fall back to clean start
          empty_state_after_orphan_kill()
      end
    else
      empty_state_after_orphan_kill()
    end
  end

  defp empty_state_after_orphan_kill do
    Helper.kill_orphaned_processes("ab-av1 encode")
    empty_state()
  end

  defp empty_state do
    %{
      video: :none,
      vmaf: :none,
      output_file: :none,
      partial_line_buffer: "",
      last_progress: nil,
      output_lines: [],
      encode_args: [],
      encoder_monitor: nil,
      os_pid: nil
    }
  end

  defp prepare_encode_state(vmaf, state) do
    case Media.mark_as_encoding(vmaf.video) do
      {:ok, _updated_video} ->
        start_encoder(vmaf, state)

      {:error, reason} ->
        Logger.error(
          "Failed to mark video #{vmaf.video.id} as encoding: #{inspect(reason)}. Skipping."
        )

        state
    end
  end

  defp start_encoder(vmaf, state) do
    args = build_encode_args(vmaf)
    ext = output_extension(vmaf.video.path)
    output_file = Path.join(Helper.temp_dir(), "#{vmaf.video.id}#{ext}")
    metadata = %{vmaf: vmaf, output_file: output_file, encode_args: args}

    case Encoder.start(args, metadata) do
      {:ok, encoder_pid} ->
        monitor = Process.monitor(encoder_pid)
        {:ok, _} = Encoder.subscribe(self())
        os_pid = Encoder.get_os_pid()

        Events.broadcast_event(:encoding_started, %{
          video_id: vmaf.video.id,
          filename: Path.basename(vmaf.video.path),
          os_pid: os_pid,
          video_size: vmaf.video.size,
          width: vmaf.video.width,
          height: vmaf.video.height,
          hdr: vmaf.video.hdr,
          video_codecs: vmaf.video.video_codecs,
          crf: vmaf.crf,
          vmaf_score: vmaf.score,
          predicted_percent: vmaf.percent,
          predicted_savings: vmaf.savings
        })

        Process.send_after(self(), :periodic_check, 10_000)

        %{
          state
          | video: vmaf.video,
            vmaf: vmaf,
            output_file: output_file,
            encode_args: args,
            output_lines: [],
            encoder_monitor: monitor,
            os_pid: os_pid
        }

      {:error, reason} ->
        Logger.error("Failed to start Encoder for video #{vmaf.video.id}: #{inspect(reason)}")

        state
    end
  end

  defp output_extension(video_path) do
    case Path.extname(video_path) |> String.downcase() do
      ".mp4" -> ".mp4"
      _ -> ".mkv"
    end
  end

  defp build_encode_args(vmaf) do
    ext = output_extension(vmaf.video.path)

    base_args = [
      "encode",
      "--crf",
      to_string(vmaf.crf),
      "--output",
      Path.join(Helper.temp_dir(), "#{vmaf.video.id}#{ext}"),
      "--input",
      vmaf.video.path
    ]

    vmaf_params = extract_vmaf_params(vmaf)
    Reencodarr.Rules.build_args(vmaf.video, :encode, vmaf_params, base_args)
  end

  defp extract_vmaf_params(%{params: params}) when is_list(params), do: params
  defp extract_vmaf_params(_), do: []

  if Mix.env() == :test do
    def build_encode_args_for_test(vmaf), do: build_encode_args(vmaf)
  end

  defp clear_state(state) do
    if state.encoder_monitor, do: Process.demonitor(state.encoder_monitor, [:flush])

    %{
      state
      | video: :none,
        vmaf: :none,
        output_file: :none,
        partial_line_buffer: "",
        last_progress: nil,
        output_lines: [],
        encode_args: [],
        encoder_monitor: nil,
        os_pid: nil
    }
  end

  defp reset_video_if_present(%{video: :none}), do: :ok

  defp reset_video_if_present(%{video: video}) do
    if is_struct(video, Reencodarr.Media.Video) do
      case Media.mark_as_crf_searched(video) do
        {:ok, _} ->
          Logger.info("Reset video #{video.id} to crf_searched state for re-queue")

        {:error, reason} ->
          Logger.error("Failed to reset video #{video.id} to crf_searched: #{inspect(reason)}")
      end
    end
  end

  defp notify_encoder_success(video, output_file) do
    PostProcessor.process_encoding_success(video, output_file)
  end

  defp notify_encoder_failure(video, exit_code, encode_args, output_lines) do
    context =
      Reencodarr.FailureTracker.build_command_context(
        encode_args,
        Enum.reverse(output_lines),
        %{exit_code: exit_code}
      )

    PostProcessor.process_encoding_failure(video, exit_code, context)
  end

  defp extract_and_store_progress(line, state) do
    progress_regex =
      ~r/(?<percent>\d+(?:\.\d+)?)%,\s+(?<fps>\d+(?:\.\d+)?)\s+fps.*?eta\s+(?<eta>[^,\n]+)/

    case Regex.named_captures(progress_regex, line) do
      %{"percent" => percent_str, "fps" => fps_str, "eta" => eta_str} ->
        progress_data = %{
          percent: String.to_float(percent_str),
          fps: String.to_float(fps_str),
          eta: String.trim(eta_str)
        }

        %{state | last_progress: progress_data}

      nil ->
        state
    end
  rescue
    _ -> state
  end
end
