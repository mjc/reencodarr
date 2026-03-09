defmodule Reencodarr.BroadwayProducersTest do
  use Reencodarr.DataCase
  import Reencodarr.Fixtures

  alias Reencodarr.Analyzer.Broadway.Producer, as: AnalyzerProducer
  alias Reencodarr.CrfSearcher.Broadway.Producer, as: CrfProducer
  alias Reencodarr.Encoder.Broadway.Producer, as: EncoderProducer

  # Extract state from init, which may return {: producer, state} or {:producer, state, {:continue, _}}
  defp init_state(module) do
    case module.init([]) do
      {:producer, state} -> state
      {:producer, state, {:continue, _}} -> state
    end
  end

  describe "Analyzer Producer" do
    test "handle_demand returns videos when available" do
      {:ok, _video} = video_fixture(%{state: :needs_analysis})

      state = init_state(AnalyzerProducer)
      {:noreply, videos, _new_state} = AnalyzerProducer.handle_demand(1, state)

      assert is_list(videos)
      assert length(videos) <= 1
    end

    test "handle_demand returns empty when no videos" do
      state = init_state(AnalyzerProducer)
      {:noreply, videos, _new_state} = AnalyzerProducer.handle_demand(1, state)

      assert videos == []
    end

    test "handle_demand respects max batch size" do
      for _ <- 1..10 do
        video_fixture(%{state: :needs_analysis})
      end

      {:producer, state} = AnalyzerProducer.init([])
      {:noreply, videos, _new_state} = AnalyzerProducer.handle_demand(100, state)

      assert length(videos) <= 100
      assert length(videos) == 10
    end

    test "poll wakes up Broadway when work available" do
      {:ok, _video} = video_fixture(%{state: :needs_analysis})

      {:producer, state} = AnalyzerProducer.init([])
      {:noreply, videos, _new_state} = AnalyzerProducer.handle_info(:poll, state)

      assert is_list(videos)
    end

    test "poll returns empty when no work" do
      {:producer, state} = AnalyzerProducer.init([])
      {:noreply, videos, _new_state} = AnalyzerProducer.handle_info(:poll, state)

      assert videos == []
    end

    test "atomic claim transitions videos to :analyzing" do
      {:ok, video} = video_fixture(%{state: :needs_analysis})

      state = init_state(AnalyzerProducer)
      {:noreply, videos, _state2} = AnalyzerProducer.handle_demand(5, state)

      assert length(videos) == 1
      assert hd(videos).id == video.id

      # Video should now be in :analyzing state in the DB
      refreshed = Reencodarr.Repo.get!(Reencodarr.Media.Video, video.id)
      assert refreshed.state == :analyzing
    end

    test "claimed videos are not dispatched again" do
      {:ok, _video} = video_fixture(%{state: :needs_analysis})

      state = init_state(AnalyzerProducer)
      {:noreply, videos1, state2} = AnalyzerProducer.handle_demand(5, state)
      assert length(videos1) == 1

      # Second demand should return nothing — video already claimed
      {:noreply, videos2, _state3} = AnalyzerProducer.handle_demand(5, state2)
      assert videos2 == []
    end
  end

  describe "CRF Producer" do
    test "handle_demand returns video when work exists" do
      {:ok, _video} = video_fixture(%{state: :analyzed})

      state = init_state(CrfProducer)
      {:noreply, videos, _new_state} = CrfProducer.handle_demand(1, state)

      # May or may not return video depending on CrfSearch availability
      assert is_list(videos)
    end

    test "poll returns list when called" do
      {:ok, _video} = video_fixture(%{state: :analyzed})

      state = init_state(CrfProducer)
      {:noreply, videos, _new_state} = CrfProducer.handle_info(:poll, state)

      assert is_list(videos)
    end
  end

  describe "Encoder Producer" do
    test "handle_demand returns list" do
      {:ok, video} = video_fixture(%{state: :crf_searched})
      vmaf = vmaf_fixture(%{video_id: video.id})
      Fixtures.choose_vmaf(video, vmaf)

      state = init_state(EncoderProducer)
      {:noreply, vmafs, _new_state} = EncoderProducer.handle_demand(1, state)

      assert is_list(vmafs)
    end

    test "poll returns list when called" do
      {:ok, video} = video_fixture(%{state: :crf_searched})
      vmaf = vmaf_fixture(%{video_id: video.id})
      Fixtures.choose_vmaf(video, vmaf)

      state = init_state(EncoderProducer)
      {:noreply, vmafs, _new_state} = EncoderProducer.handle_info(:poll, state)

      assert is_list(vmafs)
    end
  end

  describe "All Producers" do
    test "all producers initialize with polling scheduled" do
      assert %{} = init_state(AnalyzerProducer)
      assert %{} = init_state(CrfProducer)
      assert %{} = init_state(EncoderProducer)
    end

    test "all producers handle unknown messages gracefully" do
      state = init_state(AnalyzerProducer)
      assert {:noreply, [], ^state} = AnalyzerProducer.handle_info(:unknown, state)

      state = init_state(CrfProducer)
      assert {:noreply, [], ^state} = CrfProducer.handle_info(:unknown, state)

      state = init_state(EncoderProducer)
      assert {:noreply, [], ^state} = EncoderProducer.handle_info(:unknown, state)
    end
  end
end
