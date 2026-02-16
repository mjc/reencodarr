defmodule Reencodarr.Dashboard.StateTest do
  use Reencodarr.DataCase

  alias Reencodarr.Dashboard.{Events, State}
  alias Reencodarr.Media.{Video, Vmaf}
  alias Reencodarr.Repo

  setup do
    # Start the State GenServer for each test
    start_supervised!(State)
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
               }
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
    test "updates analyzer status" do
      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        "analyzer:status",
        {:analyzer, :running}
      )

      :timer.sleep(10)

      state = State.get_state()
      assert state.service_status.analyzer == :running
    end

    test "updates crf_searcher status" do
      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        "crf_searcher:status",
        {:crf_searcher, :paused}
      )

      :timer.sleep(10)

      state = State.get_state()
      assert state.service_status.crf_searcher == :paused
    end

    test "updates encoder status" do
      Phoenix.PubSub.broadcast(
        Reencodarr.PubSub,
        "encoder:status",
        {:encoder, :running}
      )

      :timer.sleep(10)

      state = State.get_state()
      assert state.service_status.encoder == :running
    end

    test "tracks multiple service status changes" do
      Phoenix.PubSub.broadcast(Reencodarr.PubSub, "analyzer:status", {:analyzer, :running})
      Phoenix.PubSub.broadcast(Reencodarr.PubSub, "crf_searcher:status", {:crf_searcher, :paused})
      Phoenix.PubSub.broadcast(Reencodarr.PubSub, "encoder:status", {:encoder, :running})

      :timer.sleep(10)

      state = State.get_state()

      assert state.service_status == %{
               analyzer: :running,
               crf_searcher: :paused,
               encoder: :running
             }
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
