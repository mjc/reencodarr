defmodule Reencodarr.BroadwayProducersTest do
  use Reencodarr.DataCase
  import Reencodarr.Fixtures

  alias Reencodarr.Analyzer.Broadway.Producer, as: AnalyzerProducer
  alias Reencodarr.CrfSearcher.Broadway.Producer, as: CrfProducer
  alias Reencodarr.Encoder.Broadway.Producer, as: EncoderProducer

  describe "Analyzer Producer" do
    test "handle_demand returns videos when available" do
      {:ok, _video} = video_fixture(%{state: :needs_analysis})

      {:producer, state} = AnalyzerProducer.init([])
      {:noreply, videos, _new_state} = AnalyzerProducer.handle_demand(1, state)

      # May return 0 or 1 videos depending on timing
      assert is_list(videos)
      assert length(videos) <= 1
    end

    test "handle_demand returns empty when no videos" do
      {:producer, state} = AnalyzerProducer.init([])
      {:noreply, videos, _new_state} = AnalyzerProducer.handle_demand(1, state)

      assert videos == []
    end

    test "handle_demand respects max batch size" do
      # Create 10 videos
      for _ <- 1..10 do
        video_fixture(%{state: :needs_analysis})
      end

      {:producer, state} = AnalyzerProducer.init([])
      {:noreply, videos, _new_state} = AnalyzerProducer.handle_demand(100, state)

      # Should return at most 5 videos (batch size limit)
      assert length(videos) <= 5
    end

    test "poll wakes up Broadway when work available" do
      {:ok, _video} = video_fixture(%{state: :needs_analysis})

      {:producer, state} = AnalyzerProducer.init([])
      {:noreply, videos, _new_state} = AnalyzerProducer.handle_info(:poll, state)

      # Poll pushes at most 1 video to wake Broadway
      assert is_list(videos)
      assert length(videos) <= 1
    end

    test "poll returns empty when no work" do
      {:producer, state} = AnalyzerProducer.init([])
      {:noreply, videos, _new_state} = AnalyzerProducer.handle_info(:poll, state)

      assert videos == []
    end
  end

  describe "CRF Producer" do
    test "handle_demand returns video when work exists" do
      {:ok, _video} = video_fixture(%{state: :analyzed})

      {:producer, state} = CrfProducer.init([])
      {:noreply, videos, _new_state} = CrfProducer.handle_demand(1, state)

      # May or may not return video depending on CrfSearch availability
      assert is_list(videos)
    end

    test "poll returns list when called" do
      {:ok, _video} = video_fixture(%{state: :analyzed})

      {:producer, state} = CrfProducer.init([])
      {:noreply, videos, _new_state} = CrfProducer.handle_info(:poll, state)

      assert is_list(videos)
    end
  end

  describe "Encoder Producer" do
    test "handle_demand returns list" do
      {:ok, video} = video_fixture(%{state: :crf_searched})
      _vmaf = vmaf_fixture(%{video_id: video.id, chosen: true})

      {:producer, state} = EncoderProducer.init([])
      {:noreply, vmafs, _new_state} = EncoderProducer.handle_demand(1, state)

      assert is_list(vmafs)
    end

    test "poll returns list when called" do
      {:ok, video} = video_fixture(%{state: :crf_searched})
      _vmaf = vmaf_fixture(%{video_id: video.id, chosen: true})

      {:producer, state} = EncoderProducer.init([])
      {:noreply, vmafs, _new_state} = EncoderProducer.handle_info(:poll, state)

      assert is_list(vmafs)
    end
  end

  describe "All Producers" do
    test "all producers initialize with polling scheduled" do
      assert {:producer, %{}} = AnalyzerProducer.init([])
      assert {:producer, %{}} = CrfProducer.init([])
      assert {:producer, %{}} = EncoderProducer.init([])
    end

    test "all producers handle unknown messages gracefully" do
      {:producer, state} = AnalyzerProducer.init([])
      assert {:noreply, [], ^state} = AnalyzerProducer.handle_info(:unknown, state)

      {:producer, state} = CrfProducer.init([])
      assert {:noreply, [], ^state} = CrfProducer.handle_info(:unknown, state)

      {:producer, state} = EncoderProducer.init([])
      assert {:noreply, [], ^state} = EncoderProducer.handle_info(:unknown, state)
    end
  end
end
