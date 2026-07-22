defmodule ReencodarrWeb.CrfSearchComponents do
  @moduledoc "Shared CRF search display components."

  use Phoenix.Component

  alias Reencodarr.AbAv1.WorkerProtocol.CrfSearchProgress
  alias Reencodarr.{Formatters, Media, Rules}
  alias ReencodarrWeb.ChartHelpers

  @service_status_styles %{
    running: "bg-green-100 text-green-800",
    paused: "bg-yellow-100 text-yellow-800",
    processing: "bg-blue-100 text-blue-800",
    pausing: "bg-orange-100 text-orange-800",
    idle: "bg-cyan-100 text-cyan-800",
    checking: "bg-gray-100 text-gray-600 dashboard-soft-pulse",
    stopped: "bg-red-100 text-red-800",
    unknown: "bg-gray-100 text-gray-800"
  }

  @service_status_labels %{
    running: "Running",
    paused: "Paused",
    processing: "Processing",
    pausing: "Pausing",
    idle: "Idle",
    checking: "Checking...",
    stopped: "Stopped",
    unknown: "Unknown"
  }

  attr :results, :list, required: true
  attr :target_vmaf, :integer, required: true
  attr :testing_crf, :float, default: nil

  def crf_search_chart(assigns) do
    scores = Enum.map(assigns.results, & &1.score)

    vmaf_min =
      min(assigns.target_vmaf - 3, Enum.min(scores, fn -> assigns.target_vmaf - 3 end) - 1)

    vmaf_max =
      max(assigns.target_vmaf + 3, Enum.max(scores, fn -> assigns.target_vmaf + 3 end) + 1)

    {crf_min, crf_max} = ChartHelpers.crf_range_from_results(assigns.results)

    dots =
      Enum.with_index(assigns.results, fn r, idx ->
        %{
          x: ChartHelpers.crf_to_x(r.crf, crf_min, crf_max),
          y: ChartHelpers.vmaf_to_y(r.score, vmaf_min, vmaf_max),
          crf: r.crf,
          score: r.score,
          above: r.score >= assigns.target_vmaf,
          is_latest: idx == length(assigns.results) - 1
        }
      end)

    target_y = ChartHelpers.vmaf_to_y(assigns.target_vmaf, vmaf_min, vmaf_max)

    y_ticks =
      for vmaf <- trunc(vmaf_min)..trunc(vmaf_max) do
        %{value: vmaf, y: ChartHelpers.vmaf_to_y(vmaf, vmaf_min, vmaf_max)}
      end

    x_ticks =
      for crf <- ChartHelpers.generate_x_ticks(trunc(crf_min), trunc(crf_max)) do
        %{value: crf, x: ChartHelpers.crf_to_x(crf, crf_min, crf_max)}
      end

    assigns =
      assign(assigns,
        vmaf_min: vmaf_min,
        vmaf_max: vmaf_max,
        crf_min: crf_min,
        crf_max: crf_max,
        dots: dots,
        target_y: target_y,
        y_ticks: y_ticks,
        x_ticks: x_ticks
      )

    ~H"""
    <svg viewBox="0 0 320 140" class="w-full" style="max-height: 200px;">
      <%= for tick <- @y_ticks do %>
        <line
          x1="30"
          y1={tick.y}
          x2="310"
          y2={tick.y}
          stroke="#374151"
          stroke-width="0.5"
          opacity="0.3"
        />
      <% end %>

      <line
        x1="30"
        y1={@target_y}
        x2="310"
        y2={@target_y}
        stroke="#f59e0b"
        stroke-width="1.5"
        stroke-dasharray="6,4"
      />
      <text x="312" y={@target_y + 3} fill="#f59e0b" font-size="9" font-family="monospace">
        {@target_vmaf}
      </text>

      <%= for dot <- @dots do %>
        <circle
          cx={dot.x}
          cy={dot.y}
          r="5"
          fill={if dot.above, do: "#4ade80", else: "#f87171"}
          opacity="0.9"
        />
        <%= if dot.is_latest do %>
          <text
            x={dot.x}
            y={dot.y - 8}
            fill="#9ca3af"
            font-size="9"
            font-family="monospace"
            text-anchor="middle"
          >
            {Formatters.vmaf_score(dot.score, 1)}
          </text>
        <% end %>
      <% end %>

      <%= if @testing_crf do %>
        <circle
          cx={ChartHelpers.crf_to_x(@testing_crf, @crf_min, @crf_max)}
          cy="115"
          r="4"
          fill="none"
          stroke="#60a5fa"
          stroke-width="1.5"
          class="dashboard-crf-beacon"
        />
        <text
          x={ChartHelpers.crf_to_x(@testing_crf, @crf_min, @crf_max)}
          y="127"
          fill="#60a5fa"
          font-size="8"
          font-family="monospace"
          text-anchor="middle"
        >
          CRF {Formatters.crf(@testing_crf)}
        </text>
      <% end %>

      <%= for tick <- @y_ticks do %>
        <text x="2" y={tick.y + 3} fill="#9ca3af" font-size="9" font-family="monospace">
          {tick.value}
        </text>
      <% end %>

      <%= for tick <- @x_ticks do %>
        <text
          x={tick.x}
          y="135"
          fill="#9ca3af"
          font-size="9"
          font-family="monospace"
          text-anchor="middle"
        >
          {tick.value}
        </text>
      <% end %>

      <line x1="30" y1="10" x2="30" y2="110" stroke="#4b5563" stroke-width="1" />
      <line x1="30" y1="110" x2="310" y2="110" stroke="#4b5563" stroke-width="1" />
    </svg>
    """
  end

  attr :video, :map, required: true
  attr :results, :list, required: true
  attr :sample, :map, required: true
  attr :id, :string, default: nil
  attr :title, :string, default: "CRF Search"
  attr :progress, :map, default: nil
  attr :queue_count, :integer, default: 0
  attr :queue_items, :list, default: []
  attr :status, :atom, required: true
  attr :show_controls, :boolean, default: true
  attr :show_queue, :boolean, default: true
  attr :show_empty_chart, :boolean, default: false
  attr :suspend_event, :string, default: "suspend_crf_search"
  attr :resume_event, :string, default: "resume_crf_search"
  attr :fail_event, :string, default: "fail_crf_search"
  attr :start_event, :string, default: nil
  attr :worker_id, :string, default: nil
  attr :job_id, :string, default: nil

  def crf_search_panel(%{progress: progress} = assigns)
      when is_nil(progress) or is_struct(progress, CrfSearchProgress) do
    ~H"""
    <div id={@id} class="dashboard-card bg-gray-900 border border-gray-700 rounded-lg p-3 sm:p-4">
      <div class="mb-3 flex flex-wrap items-center justify-between gap-2">
        <h3 class="font-semibold text-white">{@title}</h3>
        <span class={"rounded-full px-2 py-1 text-xs #{service_status_class(@status)}"}>
          {service_status_text(@status)}
        </span>
      </div>

      <%= if @video do %>
        <div class="space-y-3">
          <div class="text-sm text-gray-300">
            <div class="truncate font-medium">{@video.filename}</div>
            <div class="flex flex-wrap gap-2 text-xs text-gray-400">
              <span>{Formatters.file_size(@video.video_size)}</span>
              <span>{@video.width}x{@video.height}</span>
              <%= if @video.hdr do %>
                <span class="text-amber-400">HDR</span>
              <% end %>
              <span>Target: {@video.target_vmaf} VMAF</span>
            </div>
          </div>

          <%= if @sample do %>
            <div class="text-xs text-gray-400">
              Sample {@sample.sample_num}/{@sample.total_samples} - CRF {@sample.crf}
            </div>
          <% end %>

          <%= if @progress do %>
            <div>
              <div class="mb-1 h-2 w-full rounded-full bg-gray-800">
                <div
                  class="h-2 rounded-full bg-gradient-to-r from-amber-400 to-amber-500 transition-[width] duration-150 ease-out"
                  style={"width: #{@progress.percent}%"}
                >
                </div>
              </div>
              <div class="flex justify-between text-xs text-gray-400">
                <span>{@progress.percent}%</span>
                <%= if @progress.fps do %>
                  <span>{@progress.fps} fps</span>
                <% end %>
                <%= if @progress.eta do %>
                  <span>ETA: {@progress.eta}</span>
                <% end %>
              </div>
            </div>
          <% end %>

          <.active_job_controls
            :if={@show_controls}
            status={@status}
            suspend_event={@suspend_event}
            resume_event={@resume_event}
            fail_event={@fail_event}
            start_event={@start_event}
            worker_id={@worker_id}
            job_id={@job_id}
          />

          <%= if @show_empty_chart or length(@results) > 0 or @sample do %>
            <div class="space-y-2">
              <.crf_search_chart
                results={@results}
                target_vmaf={@video.target_vmaf}
                testing_crf={@sample && @sample.crf}
              />

              <%= if length(@results) > 0 do %>
                <div class="max-h-24 space-y-0.5 overflow-y-auto text-xs font-mono text-gray-400">
                  <%= for result <- @results do %>
                    <div class={[
                      "flex justify-between px-1",
                      @sample && result.crf == @sample.crf && "bg-blue-900/30 text-blue-200"
                    ]}>
                      <span>
                        CRF {Formatters.crf(result.crf)} -> {Formatters.vmaf_score(result.score, 1)} VMAF
                      </span>
                      <span>{if result[:percent], do: "#{result.percent}%", else: "-"}</span>
                    </div>
                  <% end %>
                </div>
              <% else %>
                <div class="px-1 text-xs text-gray-500">
                  <%= if @sample do %>
                    Sampling CRF {Formatters.crf(@sample.crf)}... waiting for first completed VMAF result.
                  <% else %>
                    Waiting for first CRF sample.
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      <% else %>
        <div class="text-sm text-gray-400">
          <span>Queue: {@queue_count}</span>
          <%= if @status == :idle do %>
            <span class="ml-2">- Idle</span>
          <% end %>
        </div>

        <%= if @show_controls and (@status == :paused or (@status == :stopped and @start_event)) do %>
          <div class="mt-2">
            <.active_job_controls
              status={@status}
              suspend_event={@suspend_event}
              resume_event={@resume_event}
              fail_event={@fail_event}
              start_event={@start_event}
              worker_id={@worker_id}
              job_id={@job_id}
            />
          </div>
        <% end %>
      <% end %>

      <%= if @show_queue and length(@queue_items) > 0 do %>
        <div class="mt-3 space-y-1 border-t border-gray-800 pt-2 text-xs text-gray-500">
          <div class="mb-0.5 text-gray-600">Next up ({@queue_count}):</div>
          <%= for video <- Enum.take(@queue_items, 5) do %>
            <div class="flex min-w-0 items-center gap-2">
              <button
                phx-click="fail_queue_video"
                phx-value-id={video.id}
                phx-value-stage="crf_search"
                title="Remove from queue"
                aria-label="Remove from queue"
                class="shrink-0 text-xs font-medium text-red-500 hover:text-red-400"
              >
                x
              </button>
              <div class="min-w-0 truncate">{Path.basename(video.path)}</div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  attr :worker, :map, required: true
  attr :crf_data, :map, default: %{}
  attr :queue_count, :integer, default: 0
  attr :queue_items, :list, default: []
  attr :show_queue, :boolean, default: false

  def worker_crf_search_panel(assigns) do
    worker = assigns.worker
    crf_data = Map.get(assigns.crf_data, active_video_id(worker), %{})

    assigns =
      assign(assigns,
        video: worker_crf_video(crf_data[:video]),
        results: worker_crf_results(crf_data[:results]),
        sample: worker_crf_sample(worker),
        status: worker_crf_status(worker)
      )

    ~H"""
    <.crf_search_panel
      id={"crf-worker-#{@worker.server_worker_id}"}
      title={"CRF Search · #{@worker.client_worker_id || @worker.server_worker_id}"}
      video={@video}
      results={@results}
      sample={@sample}
      progress={@worker.crf_search_progress}
      queue_count={@queue_count}
      queue_items={@queue_items}
      status={@status}
      show_queue={@show_queue}
      show_empty_chart={true}
      suspend_event="pause_worker_crf_search"
      resume_event="resume_worker_crf_search"
      fail_event="stop_worker_crf_search"
      start_event="start_worker_crf_search"
      worker_id={@worker.server_worker_id}
      job_id={@worker.crf_search_progress && @worker.crf_search_progress.job_id}
    />
    """
  end

  defp worker_crf_status(%{control_state: :paused}), do: :paused
  defp worker_crf_status(%{control_state: :stopped}), do: :stopped

  defp worker_crf_status(%{active_video_id: video_id}) when is_integer(video_id),
    do: :processing

  defp worker_crf_status(_worker), do: :idle

  defp worker_crf_video(%Media.Video{} = video) do
    %{
      video_id: video.id,
      filename: Path.basename(video.path),
      video_size: video.size,
      width: video.width,
      height: video.height,
      hdr: video.hdr,
      target_vmaf: Rules.vmaf_target(video)
    }
  end

  defp worker_crf_video(_video), do: nil

  defp worker_crf_results(results) when is_list(results) do
    results
    |> Enum.sort_by(& &1.crf)
    |> Enum.map(fn vmaf ->
      %{crf: vmaf.crf, score: vmaf.score, percent: vmaf.percent}
    end)
  end

  defp worker_crf_results(_results), do: []

  defp worker_crf_sample(%{
         crf_search_progress: %CrfSearchProgress{
           crf: crf,
           sample_num: sample_num,
           total_samples: total_samples
         }
       })
       when is_number(crf) and is_integer(sample_num) and is_integer(total_samples) do
    %{crf: crf, sample_num: sample_num, total_samples: total_samples}
  end

  defp worker_crf_sample(_worker), do: nil

  defp active_video_id(%{active_video_id: video_id}) when is_integer(video_id), do: video_id

  defp active_video_id(%{crf_search_progress: %CrfSearchProgress{video_id: video_id}}),
    do: video_id

  defp active_video_id(%{transfer_progress: %{video_id: video_id}}), do: video_id
  defp active_video_id(_worker), do: nil

  def load_worker_crf_data(workers, cached \\ %{}) do
    video_ids = workers |> Enum.map(&active_video_id/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Enum.reduce(video_ids, Map.take(cached, video_ids), fn video_id, data ->
      Map.put_new_lazy(data, video_id, fn ->
        %{video: Media.get_video(video_id), results: Media.get_vmafs_for_video(video_id)}
      end)
    end)
  end

  attr :status, :atom, required: true
  attr :suspend_event, :string, required: true
  attr :resume_event, :string, required: true
  attr :fail_event, :string, required: true
  attr :start_event, :string, default: nil
  attr :worker_id, :string, default: nil
  attr :job_id, :string, default: nil

  defp active_job_controls(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2 pt-1 text-xs">
      <%= if @status == :stopped and @start_event do %>
        <button
          phx-click={@start_event}
          phx-value-worker-id={@worker_id}
          phx-value-job-id={@job_id}
          class="font-medium text-green-400 hover:text-green-300"
        >
          Start
        </button>
      <% else %>
        <%= if @status == :paused do %>
          <button
            phx-click={@resume_event}
            phx-value-worker-id={@worker_id}
            phx-value-job-id={@job_id}
            class="font-medium text-cyan-400 hover:text-cyan-300"
          >
            Resume
          </button>
        <% else %>
          <button
            phx-click={@suspend_event}
            phx-value-worker-id={@worker_id}
            phx-value-job-id={@job_id}
            class="font-medium text-yellow-400 hover:text-yellow-300"
          >
            Pause
          </button>
        <% end %>
      <% end %>
      <%= unless @status == :stopped do %>
        <span class="text-gray-700">|</span>
        <button
          phx-click={@fail_event}
          phx-value-worker-id={@worker_id}
          phx-value-job-id={@job_id}
          data-confirm="Stop the active job?"
          class="font-medium text-red-500 hover:text-red-400"
        >
          Stop
        </button>
      <% end %>
    </div>
    """
  end

  defp service_status_class(status),
    do: @service_status_styles[status] || @service_status_styles.unknown

  defp service_status_text(status),
    do: @service_status_labels[status] || @service_status_labels.unknown
end
