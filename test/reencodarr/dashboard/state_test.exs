defmodule Reencodarr.Dashboard.StateTest do
  use Reencodarr.DataCase
  @moduletag capture_log: true

  alias Reencodarr.Dashboard.{Events, State}
  alias Reencodarr.Media.{Video, Vmaf}
  alias Reencodarr.Repo

  setup do
    prev = Application.get_env(:reencodarr, :dashboard_queue_refresh_enabled)
    Application.put_env(:reencodarr, :dashboard_queue_refresh_enabled, false)

    # Start the State GenServer for each test
    start_supervised!(State)

    on_exit(fn ->
      Application.put_env(:reencodarr, :dashboard_queue_refresh_enabled, prev)
    end)

    :ok
  end

  describe "get_state/0" do
    test "returns default state on startup" do
      state = State.get_state()

      assert state == %{
               crf_search_video: nil,
               crf_search_results: [],
               crf_search_sample: nil,
               crf_progress: :none,
               encoding_video: nil,
               encoding_vmaf: nil,
               encoding_progress: :none,
               service_status: %{
                 analyzer: :idle,
                 crf_searcher: :idle,
                 encoder: :idle
               },
               stats: nil,
               queue_counts: %{analyzer: 0, crf_searcher: 0, encoder: 0},
               queue_items: %{analyzer: [], crf_searcher: [], encoder: []}
             }
    end
  end

  describe "CRF search event handling" do
    test ":crf_search_started sets video and resets results" do
      video = insert_video()

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:crf_search_started, video}
      )

      # Give GenServer time to process
      :timer.sleep(10)

      state = State.get_state()
      assert state.crf_search_video.id == video.id
      assert state.crf_search_results == []
      assert state.crf_search_sample == nil
      assert state.crf_progress == :none
    end

    test ":crf_search_started sets service_status to processing" do
      video = insert_video()

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:crf_search_started, video}
      )

      :timer.sleep(10)

      state = State.get_state()
      assert state.service_status.crf_searcher == :processing
    end

    test ":crf_search_vmaf_result accumulates results sorted by CRF" do
      video = insert_video()

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:crf_search_started, video}
      )

      # Broadcast results in non-sorted order
      result1 = %{crf: 30, vmaf_score: 95.0, vmaf_percentile: 94.0, predicted_filesize: 1_000_000}
      result2 = %{crf: 25, vmaf_score: 97.0, vmaf_percentile: 96.0, predicted_filesize: 1_500_000}
      result3 = %{crf: 35, vmaf_score: 92.0, vmaf_percentile: 91.0, predicted_filesize: 800_000}

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:crf_search_vmaf_result, result1}
      )

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:crf_search_vmaf_result, result2}
      )

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:crf_search_vmaf_result, result3}
      )

      :timer.sleep(10)

      state = State.get_state()
      crfs = Enum.map(state.crf_search_results, & &1.crf)
      assert crfs == [25, 30, 35]
    end

    test ":crf_search_vmaf_result updates existing result with same CRF" do
      video = insert_video()

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:crf_search_started, video}
      )

      result1 = %{crf: 30, vmaf_score: 95.0, vmaf_percentile: 94.0, predicted_filesize: 1_000_000}

      result1_updated = %{
        crf: 30,
        vmaf_score: 95.5,
        vmaf_percentile: 94.5,
        predicted_filesize: 1_100_000
      }

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:crf_search_vmaf_result, result1}
      )

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:crf_search_vmaf_result, result1_updated}
      )

      :timer.sleep(10)

      state = State.get_state()
      assert length(state.crf_search_results) == 1
      assert hd(state.crf_search_results).vmaf_score == 95.5
    end

    test ":crf_search_encoding_sample updates sample state" do
      video = insert_video()

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:crf_search_started, video}
      )

      sample = %{crf: 28, pass: 1, total_passes: 2}

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:crf_search_encoding_sample, sample}
      )

      :timer.sleep(10)

      state = State.get_state()
      assert state.crf_search_sample == sample
    end

    test ":crf_search_progress updates progress state" do
      video = insert_video()

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:crf_search_started, video}
      )

      progress = %{fps: 30.5, eta: "00:02:30", percent: 45.0}

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:crf_search_progress, progress}
      )

      :timer.sleep(10)

      state = State.get_state()
      assert state.crf_progress == progress
    end

    test ":crf_search_completed clears all CRF state" do
      video = insert_video()

      # Set up active state
      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:crf_search_started, video}
      )

      result = %{crf: 30, vmaf_score: 95.0, vmaf_percentile: 94.0, predicted_filesize: 1_000_000}

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:crf_search_vmaf_result, result}
      )

      :timer.sleep(10)

      # Verify state is populated
      state = State.get_state()
      assert state.crf_search_video != nil

      # Complete the search
      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:crf_search_completed, %{video_id: video.id, result: :success}}
      )

      :timer.sleep(10)

      # Verify state is cleared
      state = State.get_state()
      assert state.crf_search_video == nil
      assert state.crf_search_results == []
      assert state.crf_search_sample == nil
      assert state.crf_progress == :none
    end

    test ":crf_search_failed clears all CRF state" do
      video = insert_video()

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:crf_search_started, video}
      )

      :timer.sleep(10)

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:crf_search_completed, %{video_id: video.id, result: :failed}}
      )

      :timer.sleep(10)

      state = State.get_state()
      assert state.crf_search_video == nil
      assert state.crf_search_results == []
    end
  end

  describe "encoding event handling" do
    test ":encoding_started sets video and vmaf" do
      video = insert_video()
      vmaf = insert_vmaf(video)

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:encoding_started,
         %{
           video_id: video.id,
           filename: Path.basename(video.path),
           video_size: video.size,
           width: video.width,
           height: video.height,
           hdr: video.hdr,
           video_codecs: video.video_codecs,
           crf: vmaf.crf,
           vmaf_score: vmaf.score,
           predicted_percent: vmaf.percent,
           predicted_savings: vmaf.savings
         }}
      )

      :timer.sleep(10)

      state = State.get_state()
      assert state.encoding_video.video_id == video.id
      assert state.encoding_vmaf.crf == vmaf.crf
      assert state.encoding_progress.percent == 0
    end

    test ":encoding_progress updates progress state" do
      video = insert_video()
      vmaf = insert_vmaf(video)

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:encoding_started,
         %{
           video_id: video.id,
           filename: Path.basename(video.path),
           video_size: video.size,
           crf: vmaf.crf,
           vmaf_score: vmaf.score
         }}
      )

      progress = %{fps: 45.2, eta: "01:30:00", percent: 25.5}

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:encoding_progress, progress}
      )

      :timer.sleep(10)

      state = State.get_state()
      assert state.encoding_progress == progress
    end

    test ":encoding_completed clears all encoding state" do
      video = insert_video()
      vmaf = insert_vmaf(video)

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:encoding_started,
         %{
           video_id: video.id,
           filename: Path.basename(video.path),
           video_size: video.size,
           crf: vmaf.crf,
           vmaf_score: vmaf.score
         }}
      )

      :timer.sleep(10)

      # Verify state is populated
      state = State.get_state()
      assert state.encoding_video != nil

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:encoding_completed, %{video_id: video.id, result: :success}}
      )

      :timer.sleep(10)

      # Verify state is cleared
      state = State.get_state()
      assert state.encoding_video == nil
      assert state.encoding_vmaf == nil
      assert state.encoding_progress == :none
    end

    test ":encoding_completed with error clears all encoding state" do
      video = insert_video()
      vmaf = insert_vmaf(video)

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:encoding_started,
         %{
           video_id: video.id,
           filename: Path.basename(video.path),
           video_size: video.size,
           crf: vmaf.crf,
           vmaf_score: vmaf.score
         }}
      )

      :timer.sleep(10)

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:encoding_completed, %{video_id: video.id, result: {:error, 1}}}
      )

      :timer.sleep(10)

      state = State.get_state()
      assert state.encoding_video == nil
      assert state.encoding_vmaf == nil
      assert state.encoding_progress == :none
    end
  end

  describe "service status tracking" do
    test "receives pipeline state changes from PipelineStateMachine channels" do
      # PipelineStateMachine broadcasts on "analyzer", "crf_searcher", "encoder"
      # NOT "analyzer:status" etc. State must subscribe to the correct channels.
      Phoenix.PubSub.broadcast(Reencodarr.PubSub, "analyzer", {:analyzer, :running})

      :timer.sleep(10)

      state = State.get_state()
      assert state.service_status.analyzer == :running
    end

    test "updates crf_searcher status from pipeline channel" do
      Phoenix.PubSub.broadcast(Reencodarr.PubSub, "crf_searcher", {:crf_searcher, :paused})

      :timer.sleep(10)

      state = State.get_state()
      assert state.service_status.crf_searcher == :paused
    end

    test "updates encoder status from pipeline channel" do
      Phoenix.PubSub.broadcast(Reencodarr.PubSub, "encoder", {:encoder, :running})

      :timer.sleep(10)

      state = State.get_state()
      assert state.service_status.encoder == :running
    end

    test "tracks multiple service status changes" do
      Phoenix.PubSub.broadcast(Reencodarr.PubSub, "analyzer", {:analyzer, :running})
      Phoenix.PubSub.broadcast(Reencodarr.PubSub, "crf_searcher", {:crf_searcher, :paused})
      Phoenix.PubSub.broadcast(Reencodarr.PubSub, "encoder", {:encoder, :running})

      :timer.sleep(10)

      state = State.get_state()

      assert state.service_status == %{
               analyzer: :running,
               crf_searcher: :paused,
               encoder: :running
             }
    end

    test "receives state from PipelineStateMachine via Events.pipeline_state_changed" do
      # This is the actual path: PipelineStateMachine -> Events -> PubSub -> State
      Events.pipeline_state_changed(:encoder, :idle, :running)
      :timer.sleep(10)

      state = State.get_state()
      assert state.service_status.encoder == :running

      Events.pipeline_state_changed(:encoder, :running, :processing)
      :timer.sleep(10)

      state = State.get_state()
      assert state.service_status.encoder == :processing
    end
  end

  describe "service_status lifecycle through dashboard events" do
    test "encoding lifecycle: idle -> processing -> idle" do
      state = State.get_state()
      assert state.service_status.encoder == :idle

      # encoding_started should set encoder to :processing
      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:encoding_started, %{video_id: 1, filename: "test.mkv"}}
      )

      :timer.sleep(10)

      state = State.get_state()
      assert state.service_status.encoder == :processing

      # encoding_progress should keep encoder at :processing
      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:encoding_progress, %{percent: 50, fps: 30, video_id: 1}}
      )

      :timer.sleep(10)

      state = State.get_state()
      assert state.service_status.encoder == :processing

      # encoding_completed should set encoder back to :idle
      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:encoding_completed, %{video_id: 1, result: :success}}
      )

      :timer.sleep(10)

      state = State.get_state()
      assert state.service_status.encoder == :idle
    end

    test "crf_search lifecycle: idle -> processing -> idle" do
      state = State.get_state()
      assert state.service_status.crf_searcher == :idle

      # crf_search_started should set crf_searcher to :processing
      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:crf_search_started, %{video_id: 1, filename: "test.mkv"}}
      )

      :timer.sleep(10)

      state = State.get_state()
      assert state.service_status.crf_searcher == :processing

      # crf_search_completed should set crf_searcher back to :idle
      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:crf_search_completed, %{video_id: 1, result: :success}}
      )

      :timer.sleep(10)

      state = State.get_state()
      assert state.service_status.crf_searcher == :idle
    end

    test "pipeline state overrides dashboard event status" do
      # Dashboard event sets processing
      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:encoding_started, %{video_id: 1, filename: "test.mkv"}}
      )

      :timer.sleep(10)
      assert State.get_state().service_status.encoder == :processing

      # Pipeline state change to :paused should override
      Phoenix.PubSub.broadcast(Reencodarr.PubSub, "encoder", {:encoder, :paused})
      :timer.sleep(10)
      assert State.get_state().service_status.encoder == :paused
    end

    test "encoding_started persists video and vmaf data for page reload" do
      video = insert_video()
      vmaf = insert_vmaf(video)

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:encoding_started,
         %{
           video_id: video.id,
           filename: Path.basename(video.path),
           video_size: video.size,
           width: video.width,
           height: video.height,
           hdr: video.hdr,
           video_codecs: video.video_codecs,
           crf: vmaf.crf,
           vmaf_score: vmaf.score,
           predicted_percent: vmaf.percent,
           predicted_savings: vmaf.savings
         }}
      )

      :timer.sleep(10)

      # Simulate page reload - get_state should have everything
      state = State.get_state()
      assert state.encoding_video.video_id == video.id
      assert state.encoding_video.filename == Path.basename(video.path)
      assert state.encoding_vmaf.crf == vmaf.crf
      assert state.encoding_progress.percent == 0
      assert state.service_status.encoder == :processing
    end
  end

  describe "state change broadcasting" do
    setup do
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, State.state_channel())
      :ok
    end

    test "broadcasts after encoding_started" do
      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:encoding_started, %{video_id: 1, filename: "test.mkv"}}
      )

      assert_receive {:dashboard_state_changed, state}
      assert state.encoding_video.video_id == 1
      assert state.service_status.encoder == :processing
    end

    test "broadcasts after encoding_progress" do
      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:encoding_started, %{video_id: 1, filename: "test.mkv"}}
      )

      assert_receive {:dashboard_state_changed, _}

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:encoding_progress, %{percent: 42, fps: 30, video_id: 1}}
      )

      assert_receive {:dashboard_state_changed, state}
      assert state.encoding_progress.percent == 42
    end

    test "broadcasts after encoding_completed" do
      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:encoding_started, %{video_id: 1, filename: "test.mkv"}}
      )

      assert_receive {:dashboard_state_changed, _}

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:encoding_completed, %{video_id: 1}}
      )

      assert_receive {:dashboard_state_changed, state}
      assert state.encoding_video == nil
      assert state.service_status.encoder == :idle
    end

    test "broadcasts after crf_search_started" do
      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:crf_search_started, %{video_id: 1, filename: "test.mkv"}}
      )

      assert_receive {:dashboard_state_changed, state}
      assert state.crf_search_video.video_id == 1
      assert state.service_status.crf_searcher == :processing
    end

    test "broadcasts after crf_search_completed" do
      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:crf_search_started, %{video_id: 1, filename: "test.mkv"}}
      )

      assert_receive {:dashboard_state_changed, _}

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:crf_search_completed, %{video_id: 1}}
      )

      assert_receive {:dashboard_state_changed, state}
      assert state.crf_search_video == nil
      assert state.service_status.crf_searcher == :idle
    end

    test "broadcasts after pipeline state change" do
      Events.pipeline_state_changed(:encoder, :idle, :running)

      assert_receive {:dashboard_state_changed, state}
      assert state.service_status.encoder == :running
    end

    test "broadcasts after crf_search_vmaf_result" do
      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:crf_search_started, %{video_id: 1, filename: "test.mkv"}}
      )

      assert_receive {:dashboard_state_changed, _}

      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:crf_search_vmaf_result,
         %{crf: 28, vmaf_score: 95.0, vmaf_percentile: 94.0, predicted_filesize: 1_000_000}}
      )

      assert_receive {:dashboard_state_changed, state}
      assert length(state.crf_search_results) == 1
    end

    test "broadcasts contain full state snapshot (LiveView can hydrate from it)" do
      # Verify the broadcast contains all the fields LiveView needs
      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        Events.channel(),
        {:encoding_started, %{video_id: 1, filename: "test.mkv", crf: 28, vmaf_score: 95.0}}
      )

      assert_receive {:dashboard_state_changed, state}

      # Must contain all fields that DashboardLive hydrates on mount
      assert Map.has_key?(state, :crf_search_video)
      assert Map.has_key?(state, :crf_search_results)
      assert Map.has_key?(state, :crf_search_sample)
      assert Map.has_key?(state, :crf_progress)
      assert Map.has_key?(state, :encoding_video)
      assert Map.has_key?(state, :encoding_vmaf)
      assert Map.has_key?(state, :encoding_progress)
      assert Map.has_key?(state, :service_status)
    end
  end

  # Test helpers
  defp insert_video do
    %Video{}
    |> Video.changeset(%{
      path: "/test/video.mkv",
      size: 1_000_000_000,
      state: :analyzed,
      width: 1920,
      height: 1080,
      duration: 3600.0,
      fps: 23.976,
      video_codecs: ["h264"],
      audio_codecs: ["aac"],
      container_format: "matroska"
    })
    |> Repo.insert!()
  end

  defp insert_vmaf(video) do
    %Vmaf{}
    |> Vmaf.changeset(%{
      video_id: video.id,
      crf: 28,
      score: 95.0,
      percent: 94.0,
      size: "500 MB",
      time: 3600,
      params: ["--preset", "4"],
      chosen: true
    })
    |> Repo.insert!()
  end
end
