defmodule Reencodarr.Diagnostics do
  @moduledoc """
  Live system diagnostics for Reencodarr.

  All functions return formatted strings and never crash (wrapped in rescue).
  Designed to be called via `bin/rpc` for remote inspection of running BEAM.
  """

  import Ecto.Query

  alias Reencodarr.AbAv1.{CrfSearch, Encode}
  alias Reencodarr.Analyzer
  alias Reencodarr.Analyzer.Broadway.PerformanceMonitor
  alias Reencodarr.Analyzer.MediaInfoCache
  alias Reencodarr.Core.Time
  alias Reencodarr.CrfSearcher
  alias Reencodarr.Encoder
  alias Reencodarr.Formatters
  alias Reencodarr.Media.{Video, VideoFailure}
  alias Reencodarr.Repo
  alias Reencodarr.Rules

  @doc """
  System overview: pipeline status, queue counts, video states, GenServer health.
  """
  @spec status() :: String.t()
  def status do
    # Pipeline status
    analyzer_status = Analyzer.status()
    crf_status = CrfSearcher.status()
    encoder_status = Encoder.status()

    # GenServer state
    crf_search_state = safe_call(fn -> CrfSearch.get_state() end)
    encode_available = safe_call(fn -> Encode.available?() end)

    # Video states
    video_states =
      from(v in Video, group_by: v.state, select: {v.state, count()})
      |> Repo.all()
      |> Enum.into(%{})

    # Failure count
    failure_count =
      from(f in VideoFailure, where: f.resolved == false, select: count())
      |> Repo.one()

    # Performance stats (may not exist)
    perf_stats = safe_call(fn -> PerformanceMonitor.get_performance_stats() end)
    cache_stats = safe_call(fn -> MediaInfoCache.get_stats() end)

    # Format output
    """
    #{section("System Status")}

    Pipelines:
      Analyzer:     running=#{analyzer_status.running}, active=#{analyzer_status.actively_running}, queue=#{analyzer_status.queue_count}
      CRF Searcher: running=#{crf_status.running}, active=#{crf_status.actively_running}, available=#{crf_status.available}, queue=#{crf_status.queue_count}
      Encoder:      running=#{encoder_status.running}, active=#{encoder_status.actively_running}, available=#{encoder_status.available}, queue=#{encoder_status.queue_count}

    GenServers:
      CRF Search:   #{format_genserver_state(crf_search_state)}
      Encode:       #{format_encode_available(encode_available)}

    Video States:
    #{format_video_states(video_states)}

    Failures: #{failure_count} unresolved

    #{format_performance_stats(perf_stats)}
    #{format_cache_stats(cache_stats)}
    """
  rescue
    e -> "Error in status/0: #{Exception.message(e)}"
  end

  @doc """
  Deep inspect a video by ID with all associations, VMAFs, failures, and encoding args.
  """
  @spec video(integer()) :: String.t()
  def video(id) do
    video = Repo.get(Video, id) |> Repo.preload([:vmafs, :failures, :library])

    if is_nil(video) do
      "Video #{id} not found"
    else
      vmaf_target = Rules.vmaf_target(video)
      crf_args = safe_call(fn -> Rules.build_args(video, :crf_search) end)
      encode_args = safe_call(fn -> Rules.build_args(video, :encode) end)

      """
      #{section("Video #{id}")}

      Basic Info:
        State:      #{video.state}
        Path:       #{video.path}
        Size:       #{Formatters.file_size(video.size)}
        Bitrate:    #{Formatters.bitrate(video.bitrate)}
        Resolution: #{Formatters.resolution(video.width, video.height)}
        Duration:   #{Formatters.duration(video.duration)}
        FPS:        #{Formatters.fps(video.frame_rate)}

      Codecs & Format:
        Video:      #{inspect(video.video_codecs)}
        Audio:      #{inspect(video.audio_codecs)}
        HDR:        #{video.hdr || "N/A"}
        Atmos:      #{video.atmos}

      Service Info:
        Library:    #{if video.library, do: "#{video.library.path} (ID: #{video.library_id})", else: "N/A"}
        Service:    #{video.service_type || "N/A"}
        Service ID: #{video.service_id || "N/A"}
        Title:      #{video.title || "N/A"}

      VMAFs (#{length(video.vmafs)} total):
      #{format_vmafs(video.vmafs, video.chosen_vmaf_id)}

      Failures (#{length(video.failures)} total, #{count_unresolved(video.failures)} unresolved):
      #{format_failures(video.failures)}

      Encoding Rules:
        VMAF Target: #{vmaf_target}
        CRF Search Args: #{format_args_list(crf_args)}
        Encode Args:     #{format_args_list(encode_args)}
      """
    end
  rescue
    e ->
      "Error in video/1: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
  end

  @doc """
  Find videos by path fragment.
  """
  @spec find(String.t()) :: String.t()
  def find(path_fragment) do
    # SQLite uses like (case-insensitive by default)
    pattern = "%#{path_fragment}%"

    videos =
      from(v in Video,
        where: like(v.path, ^pattern),
        order_by: [desc: v.updated_at],
        limit: 20
      )
      |> Repo.all()

    if Enum.empty?(videos) do
      "No videos found matching '#{path_fragment}'"
    else
      header = "Found #{length(videos)} video(s) matching '#{path_fragment}':\n\n"

      rows =
        Enum.map_join(videos, "\n", fn v ->
          "  #{pad(to_string(v.id), 6)} #{pad(to_string(v.state), 15)} #{pad(Formatters.file_size(v.size), 10)} #{Path.basename(v.path)}"
        end)

      header <> rows
    end
  rescue
    e -> "Error in find/1: #{Exception.message(e)}"
  end

  @doc """
  Recent unresolved failures, optionally filtered by stage.
  """
  @spec failures(atom() | nil) :: String.t()
  def failures(stage \\ nil) do
    query =
      from(f in VideoFailure,
        join: v in assoc(f, :video),
        where: f.resolved == false,
        order_by: [desc: f.inserted_at],
        limit: 20,
        select: %{
          id: f.id,
          video_id: f.video_id,
          path: v.path,
          stage: f.failure_stage,
          category: f.failure_category,
          code: f.failure_code,
          message: f.failure_message,
          inserted_at: f.inserted_at,
          has_context: not is_nil(f.system_context)
        }
      )

    query =
      if stage do
        from([f, v] in query, where: f.failure_stage == ^stage)
      else
        query
      end

    failures = Repo.all(query)

    if Enum.empty?(failures) do
      stage_msg = if stage, do: " for stage #{stage}", else: ""
      "No unresolved failures#{stage_msg}"
    else
      format_failures_list(failures)
    end
  rescue
    e -> "Error in failures/1: #{Exception.message(e)}"
  end

  @doc """
  Full failure detail including system context (command, output).
  """
  @spec failure(integer()) :: String.t()
  def failure(id) do
    failure = Repo.get(VideoFailure, id) |> Repo.preload(:video)

    if is_nil(failure) do
      "Failure #{id} not found"
    else
      ctx = failure.system_context || %{}
      command = Map.get(ctx, "command", "N/A")
      output = Map.get(ctx, "full_output", "N/A")

      """
      #{section("Failure #{id}")}

      Video:    #{failure.video_id} - #{Path.basename(failure.video.path)}
      Stage:    #{failure.failure_stage}
      Category: #{failure.failure_category}
      Code:     #{failure.failure_code}
      Message:  #{failure.failure_message}
      Retries:  #{failure.retry_count}
      Resolved: #{failure.resolved}
      Time:     #{Time.relative_time(failure.inserted_at)}

      #{section("System Context")}

      Command:
      #{command}

      Output (last 5000 chars):
      #{String.slice(output, -5000..-1//1)}
      """
    end
  rescue
    e -> "Error in failure/1: #{Exception.message(e)}"
  end

  @doc """
  Pipeline queue contents (next 10 items per queue).
  """
  @spec queues() :: String.t()
  def queues do
    analysis_queue = Analyzer.next_videos(10)
    crf_queue = CrfSearcher.next_videos(10)
    encode_queue = Encoder.next_videos(10)

    """
    #{section("Queue Contents")}

    Analysis Queue (#{Analyzer.queue_count()} total, showing #{length(analysis_queue)}):
    #{format_video_list(analysis_queue)}

    CRF Search Queue (#{CrfSearcher.queue_count()} total, showing #{length(crf_queue)}):
    #{format_video_list(crf_queue)}

    Encode Queue (#{Encoder.queue_count()} total, showing #{length(encode_queue)}):
    #{format_vmaf_list(encode_queue)}
    """
  rescue
    e -> "Error in queues/0: #{Exception.message(e)}"
  end

  @doc """
  Live GenServer state for all processing workers.
  """
  @spec processes() :: String.t()
  def processes do
    crf_state = safe_get_state(Reencodarr.AbAv1.CrfSearch, 2000)
    encode_state = safe_get_state(Reencodarr.AbAv1.Encode, 2000)
    health_state = safe_get_state(Reencodarr.Encoder.HealthCheck, 2000)
    cache_stats = safe_call(fn -> MediaInfoCache.get_stats() end)
    perf_stats = safe_call(fn -> PerformanceMonitor.get_performance_stats() end)

    """
    #{section("Live Process State")}

    CRF Search GenServer:
    #{format_crf_search_state(crf_state)}

    Encode GenServer:
    #{format_encode_state(encode_state)}

    Health Check:
    #{format_health_check_state(health_state)}

    MediaInfo Cache:
    #{format_cache_stats(cache_stats)}

    Performance Monitor:
    #{format_performance_stats(perf_stats)}
    """
  rescue
    e -> "Error in processes/0: #{Exception.message(e)}"
  end

  @doc """
  Videos that may be stuck in processing states.
  """
  @spec stuck() :: String.t()
  def stuck do
    now = DateTime.utc_now()

    processing_videos =
      from(v in Video, where: v.state in [:crf_searching, :encoding])
      |> Repo.all()

    crf_state = safe_get_state(Reencodarr.AbAv1.CrfSearch, 2000)
    encode_state = safe_get_state(Reencodarr.AbAv1.Encode, 2000)

    if Enum.empty?(processing_videos) do
      "No videos in processing states"
    else
      format_stuck_videos(processing_videos, crf_state, encode_state, now)
    end
  rescue
    e -> "Error in stuck/0: #{Exception.message(e)}"
  end

  @doc """
  Preview encoding args for a video ID (shows VMAF target + arg breakdown).
  """
  @spec video_args(integer()) :: String.t()
  def video_args(id) do
    video = Repo.get(Video, id)

    if is_nil(video) do
      "Video #{id} not found"
    else
      vmaf_target = Rules.vmaf_target(video)
      crf_args = safe_call(fn -> Rules.build_args(video, :crf_search) end)
      encode_args = safe_call(fn -> Rules.build_args(video, :encode) end)

      # Individual rule outputs
      hdr_rule = safe_call(fn -> Rules.hdr(video) end)
      res_rule = safe_call(fn -> Rules.resolution(video) end)
      video_rule = safe_call(fn -> Rules.video(video) end)
      grain_rule = safe_call(fn -> Rules.grain_for_vintage_content(video) end)
      audio_rule = safe_call(fn -> Rules.audio(video) end)

      """
      #{section("Encoding Args for Video #{id}")}

      Video: #{Path.basename(video.path)}
      Size:  #{Formatters.file_size(video.size)}
      VMAF Target: #{vmaf_target}

      CRF Search Args:
      #{format_args_list(crf_args)}

      Encode Args:
      #{format_args_list(encode_args)}

      #{section("Rule Breakdown")}

      HDR Rule:
      #{inspect(hdr_rule)}

      Resolution Rule:
      #{inspect(res_rule)}

      Video Rule:
      #{inspect(video_rule)}

      Grain Rule:
      #{inspect(grain_rule)}

      Audio Rule:
      #{inspect(audio_rule)}
      """
    end
  rescue
    e -> "Error in video_args/1: #{Exception.message(e)}"
  end

  # === Internal Helpers ===

  defp safe_call(fun) do
    fun.()
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp safe_get_state(name, timeout) do
    :sys.get_state(name, timeout)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp section(title) do
    "=== #{title} ==="
  end

  defp format_failures_list(failures) do
    header = "#{length(failures)} unresolved failure(s):\n\n"

    rows =
      Enum.map_join(failures, "\n", fn f ->
        msg = String.slice(f.message || "", 0, 60)
        ctx = if f.has_context, do: "[CTX]", else: "     "
        time = Time.relative_time(f.inserted_at)

        "  #{pad(to_string(f.id), 5)} vid=#{pad(to_string(f.video_id), 6)} #{pad(to_string(f.stage), 12)} #{pad(to_string(f.category), 10)} #{ctx} #{pad(time, 15)} #{msg}"
      end)

    header <> rows
  end

  defp format_stuck_videos(processing_videos, crf_state, encode_state, now) do
    header = "#{length(processing_videos)} video(s) in processing states:\n\n"

    rows =
      Enum.map_join(processing_videos, "\n", fn v ->
        elapsed = DateTime.diff(now, v.updated_at, :second)
        elapsed_str = format_elapsed_seconds(elapsed)
        status = determine_video_status(v, crf_state, encode_state)

        "  #{pad(to_string(v.id), 6)} #{pad(to_string(v.state), 15)} #{pad(elapsed_str, 12)} #{status} #{Path.basename(v.path)}"
      end)

    header <> rows
  end

  defp determine_video_status(video, crf_state, encode_state) do
    cond do
      video.state == :crf_searching && video_active_in_state?(crf_state, video.id) ->
        "ACTIVE in CRF"

      video.state == :encoding && video_active_in_state?(encode_state, video.id) ->
        "ACTIVE in Encode"

      true ->
        "ORPHANED?"
    end
  end

  defp pad(str, width) when is_binary(str) do
    String.pad_trailing(str, width)
  end

  defp format_elapsed_seconds(seconds) do
    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3600)}h #{rem(div(seconds, 60), 60)}m"
      true -> "#{div(seconds, 86_400)}d"
    end
  end

  defp format_genserver_state({:ok, state}) when is_map(state) do
    port = Map.get(state, :port, :unknown)
    video = Map.get(state, :video, :none)
    video_info = if video == :none, do: "idle", else: "processing video #{inspect(video)}"
    "port=#{inspect(port)}, #{video_info}"
  end

  defp format_genserver_state({:error, :not_running}), do: "not running"
  defp format_genserver_state({:error, :timeout}), do: "timeout"
  defp format_genserver_state(_), do: "unknown"

  defp format_encode_available({:ok, :available}), do: "available"
  defp format_encode_available({:ok, :busy}), do: "busy"
  defp format_encode_available({:ok, :timeout}), do: "unresponsive"
  defp format_encode_available({:ok, true}), do: "available"
  defp format_encode_available({:ok, false}), do: "busy"
  defp format_encode_available({:error, _}), do: "unavailable"
  defp format_encode_available(:available), do: "available"
  defp format_encode_available(:busy), do: "busy"
  defp format_encode_available(:timeout), do: "unresponsive"
  defp format_encode_available(true), do: "available"
  defp format_encode_available(false), do: "busy"
  defp format_encode_available(_), do: "unknown"

  defp format_video_states(states) do
    Enum.map_join(states, "\n", fn {state, count} ->
      "    #{pad(to_string(state), 20)} #{count}"
    end)
  end

  defp format_performance_stats({:error, _}), do: "Performance Monitor: unavailable"

  defp format_performance_stats(stats) when is_map(stats) do
    """
    Performance Monitor:
      Throughput:    #{Map.get(stats, :throughput, "N/A")} videos/hour
      Batch Size:    #{Map.get(stats, :batch_size, "N/A")}
      Storage Tier:  #{Map.get(stats, :storage_tier, "N/A")}
      Auto-tuning:   #{Map.get(stats, :auto_tuning_enabled, "N/A")}
    """
  end

  defp format_performance_stats(_), do: "Performance Monitor: N/A"

  defp format_cache_stats({:error, _}), do: "Cache: unavailable"

  defp format_cache_stats(stats) when is_map(stats) do
    """
    Cache:
      Size:          #{Map.get(stats, :size, "N/A")}
      Hit Rate:      #{Map.get(stats, :hit_rate, "N/A")}%
    """
  end

  defp format_cache_stats(_), do: "Cache: N/A"

  defp format_vmafs([], _chosen_vmaf_id), do: "  (none)"

  defp format_vmafs(vmafs, chosen_vmaf_id) do
    Enum.map_join(vmafs, "\n", fn v ->
      chosen = if v.id == chosen_vmaf_id, do: "[CHOSEN]", else: "        "
      savings_str = if v.savings, do: Formatters.file_size(v.savings), else: "N/A"

      "  #{chosen} CRF=#{pad(to_string(v.crf), 4)} VMAF=#{pad(Formatters.vmaf_score(v.score), 6)} Percent=#{pad(to_string(v.percent), 6)} Savings=#{savings_str}"
    end)
  end

  defp format_failures([]), do: "  (none)"

  defp format_failures(failures) do
    unresolved = Enum.reject(failures, & &1.resolved)

    if Enum.empty?(unresolved) do
      "  (all resolved)"
    else
      Enum.map_join(unresolved, "\n", &format_failure_line/1)
    end
  end

  defp format_failure_line(f) do
    msg = String.slice(f.failure_message || "", 0, 80)
    ctx = if f.system_context, do: "[HAS_CTX]", else: "        "
    time = Time.relative_time(f.inserted_at)

    "  #{pad(to_string(f.failure_stage), 12)} #{pad(to_string(f.failure_category), 10)} #{ctx} #{time}\n     #{msg}"
  end

  defp count_unresolved(failures) do
    Enum.count(failures, &(not &1.resolved))
  end

  defp format_args_list({:error, _}), do: "  Error generating args"
  defp format_args_list([]), do: "  (none)"

  defp format_args_list(args) when is_list(args) do
    args
    |> Enum.chunk_every(8)
    |> Enum.map_join("\n", &("  " <> Enum.join(&1, " ")))
  end

  defp format_args_list(_), do: "  N/A"

  defp format_video_list([]), do: "  (empty)"

  defp format_video_list(videos) do
    Enum.map_join(videos, "\n", fn v ->
      "  #{pad(to_string(v.id), 6)} #{pad(Formatters.file_size(v.size), 10)} #{Path.basename(v.path)}"
    end)
  end

  defp format_vmaf_list([]), do: "  (empty)"

  defp format_vmaf_list(vmafs) do
    Enum.map_join(vmafs, "\n", fn v ->
      video = Map.get(v, :video)

      if video do
        "  #{pad(to_string(video.id), 6)} #{pad(Formatters.file_size(video.size), 10)} #{Path.basename(video.path)}"
      else
        "  vmaf_id=#{v.id} (video not preloaded)"
      end
    end)
  end

  defp format_crf_search_state({:error, _}), do: "  Unavailable"

  defp format_crf_search_state(state) when is_map(state) do
    port = Map.get(state, :port, :none)
    video = Map.get(state, :video, :none)

    port_str = if port == :none, do: "idle", else: "active"

    video_str =
      if video == :none, do: "none", else: "video_id=#{inspect(Map.get(video, :id, "unknown"))}"

    "  Port: #{port_str}\n  Video: #{video_str}"
  end

  defp format_crf_search_state(_), do: "  Unknown state"

  defp format_encode_state({:error, _}), do: "  Unavailable"

  defp format_encode_state(state) when is_map(state) do
    port = Map.get(state, :port, :none)
    video = Map.get(state, :video, :none)

    port_str = if port == :none, do: "idle", else: "active"

    video_str =
      if video == :none, do: "none", else: "video_id=#{inspect(Map.get(video, :id, "unknown"))}"

    "  Port: #{port_str}\n  Video: #{video_str}"
  end

  defp format_encode_state(_), do: "  Unknown state"

  defp format_health_check_state({:error, _}), do: "  Unavailable"

  defp format_health_check_state(state) when is_map(state) do
    encoding = Map.get(state, :encoding, false)
    video_id = Map.get(state, :video_id)
    last_progress = Map.get(state, :last_progress_time)
    warned = Map.get(state, :warned, false)
    os_pid = Map.get(state, :os_pid)

    """
      Encoding:      #{encoding}
      Video ID:      #{video_id || "none"}
      Last Progress: #{if last_progress, do: Time.relative_time(last_progress), else: "N/A"}
      Warned:        #{warned}
      OS PID:        #{os_pid || "N/A"}
    """
  end

  defp format_health_check_state(_), do: "  Unknown state"

  defp video_active_in_state?({:error, _}, _video_id), do: false

  defp video_active_in_state?(state, video_id) when is_map(state) do
    video = Map.get(state, :video, :none)

    case video do
      :none -> false
      %{id: ^video_id} -> true
      _ -> false
    end
  end

  defp video_active_in_state?(_, _), do: false
end
