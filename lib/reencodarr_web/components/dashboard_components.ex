defmodule ReencodarrWeb.DashboardComponents do
  @moduledoc false
  use ReencodarrWeb, :html

  alias Reencodarr.AbAv1.{LocalWorker, WorkerConfig}
  alias Reencodarr.{Formatters, Rules}
  alias ReencodarrWeb.{CrfSearchComponents, WorkerActivity}

  def dashboard(assigns) do
    ~H"""
    <div id="dashboard-root" class="workbench">
      <header class="workbench-heading">
        <h1>Dashboard</h1>
        <div class="workbench-heading-actions">
          <span class="connection-label"><span class="status-dot" />Live</span>
          <details id="source-sync-menu" class="sync-menu" phx-mounted={JS.ignore_attributes("open")}>
            <summary class="workbench-button"><.icon name="hero-arrow-path" />Sync sources</summary>
            <div class="workbench-menu">
              <button
                :for={source <- @sources}
                phx-click={"sync_#{source.type}"}
                disabled={@syncing or source.enabled != true}
              >
                Sync {source.name}
              </button>
            </div>
          </details>
        </div>
      </header>

      <nav class="workflow" aria-label="Processing workflow">
        <.workflow_stage
          id="workflow-analyze"
          name="Analyze"
          owner="Server"
          icon="hero-document-magnifying-glass"
          count={@queue_counts.analyzer}
          status={@service_status.analyzer}
        />
        <.icon name="hero-chevron-right" class="workflow-connector" />
        <.workflow_stage
          id="workflow-crf-search"
          name="CRF search"
          owner="Workers"
          icon="hero-magnifying-glass"
          count={@queue_counts.crf_searcher}
        />
        <.icon name="hero-chevron-right" class="workflow-connector" />
        <.workflow_stage
          id="workflow-encode"
          name="Encode"
          owner="Workers"
          icon="hero-play"
          count={@queue_counts.encoder}
        />
      </nav>

      <div class="workbench-columns">
        <section id="dashboard-workers" class="workbench-workers" aria-labelledby="workers-heading">
          <div class="section-heading">
            <h2 id="workers-heading">Workers</h2>
            <span>{length(@workers)} connected</span>
            <.link navigate={~p"/workers"} class="section-action">Manage workers</.link>
          </div>
          <div id="dashboard-active-work" class="worker-list">
            <.worker_group
              :for={worker <- @workers}
              worker={worker}
              encode_data={@encode_worker_data}
              crf_data={@crf_worker_data}
            />
            <div :if={@workers == []} class="workbench-empty">
              <.icon name="hero-server-stack" />
              <h3>No workers connected</h3>
              <.link navigate={~p"/workers"} class="workbench-button">Worker setup</.link>
            </div>
          </div>

          <section class="recent-encodes" aria-labelledby="recent-heading">
            <div class="section-heading">
              <h2 id="recent-heading">Recent encodes</h2>
              <.link navigate={~p"/videos?state=encoded"} class="section-action">View encoded videos</.link>
            </div>
            <p :if={@recent_encodes == []} class="workbench-empty-inline">
              {if(@stats.encoded > 0,
                do: "Recent encodes unavailable.",
                else: "No encoded videos yet."
              )}
            </p>
            <div :if={@recent_encodes != []} class="workbench-table-scroll">
              <table class="workbench-table">
                <thead>
                  <tr>
                    <th scope="col">Title</th><th scope="col">Resolution</th><th scope="col">VMAF</th><th scope="col">
                      Space saved
                    </th><th scope="col">Updated</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={video <- @recent_encodes}>
                    <td title={video.path}>{video_name(video)}</td>
                    <td>{resolution(video)}</td>
                    <td>
                      {if(is_nil(video.vmaf), do: "—", else: Formatters.vmaf_score(video.vmaf, 1))}
                    </td>
                    <td>{Formatters.file_size(video.space_saved_bytes)}</td>
                    <td>
                      <time datetime={DateTime.to_iso8601(video.updated_at)}>{Formatters.relative_time(
                        video.updated_at
                      )}</time>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>
        </section>

        <aside class="workbench-aside">
          <section id="dashboard-queue" class="workbench-panel" aria-labelledby="queue-heading">
            <h2 id="queue-heading" class="panel-heading">Queue</h2>
            <div class="queue-tabs" role="group" aria-label="Queue stage">
              <button
                :for={
                  {stage, name} <- [
                    {:analyzer, "Analyze"},
                    {:crf_searcher, "CRF search"},
                    {:encoder, "Encode"}
                  ]
                }
                phx-click="select_queue"
                phx-value-stage={stage}
                aria-pressed={to_string(@selected_queue == stage)}
              >{name}</button>
            </div>
            <ul class="queue-list">
              <li :for={video <- Map.fetch!(@queue_items, @selected_queue)}>
                <.icon name="hero-document" class="queue-file-icon" />
                <div class="queue-file">
                  <strong title={video.path}>{video_name(video)}</strong>
                  <span>{resolution(video)}<span :if={Map.get(video, :service_type)}>{source_name(
                    video.service_type
                  )}</span></span>
                </div>
                <span class="queue-size">{Formatters.file_size(Map.get(video, :size))}</span>
                <button
                  :if={@selected_queue != :analyzer}
                  class="queue-remove"
                  phx-click="fail_queue_video"
                  phx-value-id={video.id}
                  phx-value-stage={
                    if(@selected_queue == :encoder, do: "encoding", else: "crf_search")
                  }
                  aria-label={"Remove #{video_name(video)} from queue"}
                  data-confirm="Remove this video from the queue and mark it failed?"
                >
                  <.icon name="hero-x-mark" />
                </button>
              </li>
            </ul>
            <p :if={Map.fetch!(@queue_items, @selected_queue) == []} class="workbench-empty-inline">
              {if(Map.fetch!(@queue_counts, @selected_queue) > 0,
                do: "Loading queue…",
                else: "Queue empty"
              )}
            </p>
            <.link
              navigate={~p"/videos?state=#{queue_state(@selected_queue)}"}
              class="workbench-button queue-view"
            >View queue</.link>
          </section>

          <section class="workbench-panel source-sync" aria-labelledby="source-heading">
            <h2 id="source-heading" class="panel-heading">Source sync</h2>
            <ul>
              <li :for={source <- @sources} id={"source-sync-#{source.type}"}>
                <span class={["status-dot", source.enabled != true && "status-dot-muted"]} />
                <strong>{source.name}</strong>
                <span
                  :if={@syncing and @service_type == source.type}
                  class="source-sync-progress"
                  role="status"
                >
                  <progress
                    max="100"
                    value={@sync_progress}
                    aria-label={"#{source.name} sync progress"}
                  />
                  <span>{round(@sync_progress)}%</span>
                </span>
                <span :if={!@syncing or @service_type != source.type}>{source_status(source)}</span>
              </li>
            </ul>
            <.link navigate={~p"/configs"} class="section-action">Configure sources</.link>
          </section>
        </aside>
      </div>

      <footer class="workbench-summary">
        <span><.icon name="hero-film" /><strong>{@stats_display.total_videos}</strong> videos</span>
        <span><.icon name="hero-circle-stack" /><strong>{@stats_display.completed}</strong> encoded</span>
        <span><.icon name="hero-archive-box" /><strong>{@stats_display.savings} TiB</strong>
        space saved</span>
        <.link :if={(@stats.failed || 0) > 0} navigate={~p"/failures"} class="summary-issues">{@stats_display.failures} failures</.link>
      </footer>
    </div>
    """
  end

  def worker_setup(assigns) do
    token = Application.get_env(:reencodarr, :worker_token)

    fingerprint =
      if is_binary(token) and String.trim(token) != "" do
        "sha256:" <> binary_part(Base.encode16(:crypto.hash(:sha256, token), case: :lower), 0, 12)
      else
        "Not configured"
      end

    url =
      ReencodarrWeb.Endpoint.url()
      |> String.replace_prefix("https://", "wss://")
      |> String.replace_prefix("http://", "ws://")

    process = if Process.whereis(LocalWorker), do: LocalWorker.status(), else: nil

    status =
      cond do
        WorkerConfig.execution_mode() != :worker -> "Disabled"
        process && process.running -> "Running"
        true -> "Not running"
      end

    assigns =
      assign(assigns,
        fingerprint: fingerprint,
        url: url <> "/workers/socket/websocket",
        process_status: status
      )

    ~H"""
    <details
      id="worker-setup"
      class="workbench-panel worker-setup"
      phx-mounted={JS.ignore_attributes("open")}
    >
      <summary>Worker setup</summary>
      <dl>
        <dt>Local worker process</dt><dd>{@process_status}</dd>
        <dt>Worker WebSocket</dt><dd><code>{@url}?token=&lt;worker-token&gt;</code></dd>
        <dt>Token fingerprint</dt><dd>{@fingerprint}</dd>
      </dl>
    </details>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :owner, :string, required: true
  attr :icon, :string, required: true
  attr :count, :integer, required: true
  attr :status, :atom, default: nil

  defp workflow_stage(assigns) do
    ~H"""
    <div id={@id} class="workflow-stage">
      <.icon name={@icon} />
      <div><strong>{@name}</strong><small>{@owner}</small></div>
      <span :if={@status} class="stage-status">{status_label(@status)}</span>
      <span class="workflow-count">{@count} queued</span>
    </div>
    """
  end

  attr :worker, :map, required: true
  attr :encode_data, :map, required: true
  attr :crf_data, :map, required: true

  def worker_group(assigns) do
    jobs =
      assigns.worker.jobs
      |> Map.values()
      |> Enum.filter(& &1.active)
      |> Enum.sort_by(&{if(&1.job_type == :encode, do: 0, else: 1), &1.job_id})

    assigns = assign(assigns, jobs: jobs, name: worker_name(assigns.worker))

    ~H"""
    <section id={"worker-#{@name}"} class="worker-group" aria-label={"Worker #{@name}"}>
      <header class="worker-heading">
        <h3>{@name}</h3>
        <span class="connection-label"><span class="status-dot" />Connected</span>
        <div class="worker-resources">
          <span>CPU <strong>{cpu(@worker)}</strong></span>
          <span>Memory <strong>{memory(@worker)}</strong></span>
          <span :if={get_in(@worker, [:resource_usage, :disk_free_bytes])}>Disk
          <strong>{disk(@worker)}</strong></span>
        </div>
      </header>
      <.job_row
        :for={job <- @jobs}
        job={job}
        worker={@worker}
        data={if(job.job_type == :encode, do: @encode_data, else: @crf_data)}
      />
      <div :if={@jobs == []} class="worker-idle">
        <strong>{if(@worker.control_state == :stopped, do: "Stopped", else: "Idle")}</strong><span>No active jobs</span>
        <button
          :if={@worker.control_state == :stopped}
          class="workbench-button"
          phx-click="start_worker_crf_search"
          phx-value-worker-id={@worker.server_worker_id}
        >Start</button>
      </div>
    </section>
    """
  end

  attr :job, :map, required: true
  attr :worker, :map, required: true
  attr :data, :map, required: true

  defp job_row(assigns) do
    data = Map.get(assigns.data, assigns.job.video_id, %{})
    prefix = if assigns.job.job_type == :encode, do: "encode", else: "crf"
    # Preserve the primary job's stable DOM ID across reconnects.
    same_type =
      assigns.worker.jobs
      |> Map.values()
      |> Enum.filter(&(&1.active and &1.job_type == assigns.job.job_type))
      |> Enum.sort_by(& &1.job_id)

    suffix = if hd(same_type).job_id == assigns.job.job_id, do: "", else: "-#{assigns.job.job_id}"

    assigns =
      assign(assigns,
        video: data[:video],
        vmaf: data[:vmaf],
        results: data[:results] || [],
        progress: progress_map(assigns.job.progress),
        transfer: progress_map(assigns.job.transfer_progress),
        status: job_status(assigns.job),
        dom_id: "#{prefix}-worker-#{worker_name(assigns.worker)}#{suffix}"
      )

    ~H"""
    <article id={@dom_id} class={["worker-job", @job.job_type == :crf_search && "worker-job-search"]}>
      <.icon name="hero-document" class="job-file-icon" />
      <div class="job-content">
        <div class="job-heading">
          <div class="job-title">
            <h4 title={@video && @video.path}>
              {if(@video, do: video_name(@video), else: "Video #{@job.video_id}")}
            </h4>
            <div :if={@video} class="job-metadata">
              <span>{resolution(@video)}</span><span>{Enum.join(@video.video_codecs || [], ", ")} to AV1</span><span :if={
                @video.hdr
              }>HDR</span>
            </div>
          </div>
          <div class="job-controls" aria-label="Job controls">
            <button
              class="workbench-button"
              phx-click={control_event(@job, @status)}
              phx-value-worker-id={@worker.server_worker_id}
              phx-value-job-id={@job.job_id}
              disabled={@status == :pending}
              aria-label={"#{if(@status == :paused, do: "Resume", else: "Pause")} #{if(@video, do: video_name(@video), else: "job")}"}
            >
              <.icon name={if(@status == :paused, do: "hero-play", else: "hero-pause")} />{if(
                @status == :paused,
                do: "Resume",
                else: "Pause"
              )}
            </button>
            <button
              class="workbench-button button-stop"
              phx-click={"stop_worker_#{@job.job_type}"}
              phx-value-worker-id={@worker.server_worker_id}
              phx-value-job-id={@job.job_id}
              disabled={@status == :pending}
              data-confirm="Stop this job and mark the video failed?"
              aria-label={"Stop #{if(@video, do: video_name(@video), else: "job")}"}
            ><.icon name="hero-stop" />Stop</button>
          </div>
        </div>
        <div class="job-progress-line">
          <span class="job-type">{if(@job.job_type == :encode, do: "Encode", else: "CRF search")}</span>
          <span :if={@status != :processing} class="job-status" role="status">{status_label(@status)}</span>
          <%= if @job.job_type == :encode and is_number(@progress[:percent]) do %>
            <progress max="100" value={clamp(@progress.percent)} aria-label="Encode progress" />
            <strong>{Formatters.rate(@progress.percent)}%</strong>
          <% end %>
          <%= if @job.job_type == :crf_search and @job.phase == :crf_searching do %>
            <span :if={is_number(@progress[:crf])}>Testing CRF {Formatters.crf(@progress.crf)}</span>
            <progress
              :if={@progress[:sample_num] && @progress[:total_samples] && @progress.total_samples > 0}
              max={@progress.total_samples}
              value={@progress.sample_num}
              aria-label="CRF sample progress"
            />
            <span :if={@progress[:sample_num] && @progress[:total_samples]}>Sample {@progress.sample_num}/{@progress.total_samples}</span>
            <span :if={@video}>Target VMAF {Rules.vmaf_target(@video)}</span>
          <% end %>
        </div>
        <div :if={@job.job_type == :encode and @job.phase == :encoding} class="job-metrics">
          <span :if={@progress[:fps]}>{Formatters.rate(@progress.fps)} fps</span>
          <span :if={@progress[:eta]}>{Formatters.eta(@progress.eta)} remaining</span>
          <span :if={@vmaf}>CRF {Formatters.crf(@vmaf.crf)}</span>
          <span :if={@vmaf}>VMAF {Formatters.vmaf_score(@vmaf.score, 1)}</span>
          <span
            :if={@vmaf && is_integer(@vmaf.savings) && @vmaf.savings >= 0}
            data-role="estimated-savings"
          >
            Est. savings {Formatters.file_size(@vmaf.savings)}
          </span>
        </div>
        <div :if={@job.phase not in [:encoding, :crf_searching, :assigned]} class="job-metadata">
          <span>{phase_label(@job.phase)}</span>
          <span :if={is_number(@transfer[:percent])}>{Formatters.rate(@transfer.percent)}%</span>
        </div>
        <.transfer_info
          :if={@job.phase in [:receiving_input, :output_upload] and @transfer != %{}}
          progress={@transfer}
        />
        <p :if={@job.recovery_action} class="job-warning">{WorkerActivity.label(@job)}</p>
        <details
          :if={(@job.job_type == :crf_search and @video) && @results != []}
          id={"#{@dom_id}-results"}
          class="job-details"
          phx-mounted={JS.ignore_attributes("open")}
        >
          <summary>Search results</summary>
          <CrfSearchComponents.crf_search_chart
            results={Enum.map(@results, &%{crf: &1.crf, score: &1.score})}
            target_vmaf={Rules.vmaf_target(@video)}
            testing_crf={@progress[:crf]}
          />
          <ul class="search-results">
            <li :for={result <- @results}>
              CRF {Formatters.crf(result.crf)}: VMAF {Formatters.vmaf_score(result.score, 1)}
            </li>
          </ul>
        </details>
      </div>
    </article>
    """
  end

  attr :progress, :map, required: true

  defp transfer_info(assigns) do
    ~H"""
    <div class="transfer-info">
      <progress
        :if={is_number(@progress[:percent])}
        max="100"
        value={clamp(@progress.percent)}
        aria-label="File transfer progress"
      />
      <div class="job-metrics">
        <span>{Formatters.file_size(@progress[:bytes_sent])} / {Formatters.file_size(
          @progress[:total_bytes]
        )}</span>
        <span :if={
          is_integer(@progress[:total_chunks]) and @progress.total_chunks > 0 and
            is_integer(@progress[:chunk_index])
        }>Chunk {@progress.chunk_index + 1} / {@progress.total_chunks}</span>
        <span :if={is_number(@progress[:bytes_per_second])}>{Formatters.file_size(
          round(@progress.bytes_per_second)
        )}/s</span>
        <span :if={@progress[:eta]}>ETA {Formatters.eta(@progress.eta)}</span>
      </div>
    </div>
    """
  end

  defp progress_map(nil), do: %{}
  defp progress_map(progress) when is_struct(progress), do: Map.from_struct(progress)
  defp progress_map(progress), do: progress

  defp worker_name(worker), do: worker.client_worker_id || worker.server_worker_id
  defp video_name(%{title: title}) when is_binary(title) and title != "", do: title
  defp video_name(video), do: Path.basename(video.path)
  defp resolution(%{height: height}) when is_integer(height) and height > 0, do: "#{height}p"
  defp resolution(_), do: "—"

  defp cpu(%{resource_usage: %{cpu_percent: percent}}) when is_number(percent),
    do: "#{Formatters.rate(percent)}%"

  defp cpu(_), do: "—"

  defp memory(%{resource_usage: %{memory_bytes: bytes, memory_total_bytes: total}})
       when is_integer(bytes) and is_integer(total) and total > 0,
       do: "#{Formatters.file_size(bytes)} / #{Formatters.file_size(total)}"

  defp memory(%{resource_usage: %{memory_bytes: bytes}}) when is_integer(bytes),
    do: Formatters.file_size(bytes)

  defp memory(_), do: "—"

  defp disk(%{resource_usage: %{disk_free_bytes: free, disk_total_bytes: total}})
       when is_integer(total) and total > 0,
       do: "#{Formatters.file_size(free)} free / #{Formatters.file_size(total)}"

  defp disk(%{resource_usage: %{disk_free_bytes: free}}), do: "#{Formatters.file_size(free)} free"
  defp clamp(percent), do: max(0, min(100, percent))
  defp queue_state(:analyzer), do: :needs_analysis
  defp queue_state(:crf_searcher), do: :analyzed
  defp queue_state(:encoder), do: :crf_searched
  defp source_name("sonarr"), do: "Sonarr"
  defp source_name("radarr"), do: "Radarr"
  defp source_name("sportarr"), do: "Sportarr"
  defp source_name(:sonarr), do: "Sonarr"
  defp source_name(:radarr), do: "Radarr"
  defp source_name(:sportarr), do: "Sportarr"
  defp source_name(_), do: ""
  defp source_status(%{configured: false}), do: "Not configured"
  defp source_status(%{enabled: false}), do: "Disabled"
  defp source_status(%{last_synced_at: nil}), do: "Never synced"
  defp source_status(source), do: Formatters.relative_time(source.last_synced_at)

  defp phase_label(phase),
    do: phase |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  defp status_label(:pending), do: "Awaiting ACK"
  defp status_label(:processing), do: "Processing"
  defp status_label(:running), do: "Running"
  defp status_label(:paused), do: "Paused"
  defp status_label(:idle), do: "Idle"
  defp status_label(:stopped), do: "Stopped"
  defp status_label(_), do: "Checking"

  defp job_status(%{
         control_command_id: id,
         desired_control_state: desired,
         control_state: actual
       })
       when is_binary(id) and desired != actual, do: :pending

  defp job_status(%{control_state: :paused}), do: :paused
  defp job_status(_), do: :processing
  defp control_event(job, :paused), do: "resume_worker_#{job.job_type}"
  defp control_event(job, _status), do: "pause_worker_#{job.job_type}"
end
