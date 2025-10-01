IEx.configure(auto_reload: true)

# Core modules
alias Reencodarr.{Media, Repo, Rules, Services, Sync, Config}
alias Reencodarr.Media.{Video, Library, Vmaf}

# Broadway pipelines and workers
alias Reencodarr.{Analyzer, CrfSearcher, Encoder}
alias Reencodarr.Analyzer.Broadway
alias Reencodarr.AbAv1.{CrfSearch, Encode}

# State management
alias Reencodarr.PipelineStateMachine

# Dashboard and events
alias Reencodarr.Dashboard.Events
alias ReencodarrWeb.{Endpoint, Router}

import Ecto.Query

# Utility functions for debugging
defmodule IExHelpers do
  @doc "Show status of all Broadway pipelines"
  def pipelines_status do
    %{
      analyzer: Analyzer.status(),
      crf_searcher: CrfSearcher.status(),
      encoder: Encoder.status()
    }
  end

  @doc "Get count of items in each queue"
  def queue_counts do
    %{
      analysis: Analyzer.queue_count(),
      crf_search: CrfSearcher.queue_count(),
      encoding: Encoder.queue_count()
    }
  end

  @doc "Get next items in each queue"
  def next_items(limit \\ 5) do
    %{
      analysis: Analyzer.next_videos(limit),
      crf_search: CrfSearcher.next_videos(limit),
      encoding: Encoder.next_videos(limit)
    }
  end

  @doc "Start all pipelines"
  def start_all do
    Analyzer.start()
    CrfSearcher.start()
    Encoder.start()
    pipelines_status()
  end

  @doc "Pause all pipelines"
  def pause_all do
    Analyzer.pause()
    CrfSearcher.pause()
    Encoder.pause()
    pipelines_status()
  end

  @doc "Get video by path (fuzzy match)"
  def find_video(path_fragment) do
    from(v in Video, where: ilike(v.path, ^"%#{path_fragment}%"))
    |> Repo.all()
  end

  @doc "Get service configs"
  def configs do
    Services.list_services()
  end

  @doc "Quick video state summary"
  def video_states do
    from(v in Video,
      group_by: v.state,
      select: {v.state, count()}
    )
    |> Repo.all()
    |> Enum.into(%{})
  end

  @doc "Debug a specific video"
  def debug_video(id) when is_integer(id) do
    video = Repo.get!(Video, id) |> Repo.preload(:vmafs)

    %{
      video: video,
      vmaf_count: length(video.vmafs),
      chosen_vmaf: Enum.find(video.vmafs, & &1.chosen),
      service: Services.get_service_by_id(video.service_id)
    }
  end
end

# Import the helper functions
import IExHelpers

# Welcome message
IO.puts("""

🚀 Reencodarr IEx Console Ready!

Quick commands:
  pipelines_status()  - Check all Broadway pipeline status
  queue_counts()      - Get queue counts for all pipelines
  next_items()        - See next items in each queue
  start_all() / pause_all() - Control all pipelines
  video_states()      - Summary of video states
  find_video("path")  - Find videos by path fragment
  debug_video(123)    - Debug specific video by ID
  configs()           - List service configurations

Happy debugging! 🎬
""")
