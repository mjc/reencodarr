defmodule Reencodarr.AbAv1.QueueManagerTest do
  use Reencodarr.UnitCase, async: true
  doctest Reencodarr.AbAv1.QueueManager

  alias Reencodarr.AbAv1.QueueManager

  describe "calculate_queue_lengths/1" do
    test "calculates queue lengths for multiple servers" do
      servers = [
        {:crf_searches, self()},
        {:encodes, self()}
      ]

      result = QueueManager.calculate_queue_lengths(servers)

      assert is_map(result)
      assert Map.has_key?(result, :crf_searches)
      assert Map.has_key?(result, :encodes)
      assert is_integer(result.crf_searches)
      assert is_integer(result.encodes)
    end

    test "handles empty server list" do
      result = QueueManager.calculate_queue_lengths([])
      assert result == %{}
    end

    test "handles non-existent servers gracefully" do
      servers = [
        {:crf_searches, :non_existent_server},
        {:encodes, make_ref()}
      ]

      result = QueueManager.calculate_queue_lengths(servers)

      assert result == %{crf_searches: 0, encodes: 0}
    end
  end

  describe "get_queue_length_for_server/1" do
    test "returns 0 for current process (no queue)" do
      assert QueueManager.get_queue_length_for_server(self()) == 0
    end

    test "returns 0 for non-existent atom server" do
      assert QueueManager.get_queue_length_for_server(:non_existent) == 0
    end

    test "returns 0 for invalid server types" do
      assert QueueManager.get_queue_length_for_server("invalid") == 0
      assert QueueManager.get_queue_length_for_server(123) == 0
      assert QueueManager.get_queue_length_for_server(nil) == 0
    end
  end

  describe "validate_crf_search_request/2" do
    test "validates valid video and vmaf_percent" do
      video = %{id: 123, path: "/test.mkv"}
      assert QueueManager.validate_crf_search_request(video, 95) == {:ok, {video, 95}}
    end

    test "rejects invalid video" do
      assert QueueManager.validate_crf_search_request(nil, 95) == {:error, :invalid_video}
      assert QueueManager.validate_crf_search_request("not a map", 95) == {:error, :invalid_video}

      assert QueueManager.validate_crf_search_request(%{no_id: true}, 95) ==
               {:error, :invalid_video}
    end

    test "rejects invalid vmaf_percent" do
      video = %{id: 123, path: "/test.mkv"}

      assert QueueManager.validate_crf_search_request(video, 150) ==
               {:error, :invalid_vmaf_percent}

      assert QueueManager.validate_crf_search_request(video, 30) ==
               {:error, :invalid_vmaf_percent}

      assert QueueManager.validate_crf_search_request(video, "95") ==
               {:error, :invalid_vmaf_percent}
    end

    test "accepts valid vmaf_percent range" do
      video = %{id: 123, path: "/test.mkv"}
      assert {:ok, _} = QueueManager.validate_crf_search_request(video, 50)
      assert {:ok, _} = QueueManager.validate_crf_search_request(video, 75)
      assert {:ok, _} = QueueManager.validate_crf_search_request(video, 100)
    end
  end

  describe "validate_encode_request/1" do
    test "validates valid vmaf struct" do
      vmaf = %{id: 456, video_id: 123, crf: 28.0}
      assert QueueManager.validate_encode_request(vmaf) == {:ok, vmaf}
    end

    test "rejects invalid vmaf" do
      assert QueueManager.validate_encode_request(nil) == {:error, :invalid_vmaf}
      assert QueueManager.validate_encode_request("not a map") == {:error, :invalid_vmaf}
      assert QueueManager.validate_encode_request(%{no_id: true}) == {:error, :invalid_vmaf}
    end

    test "rejects vmaf without video_id" do
      vmaf = %{id: 456, crf: 28.0}
      assert QueueManager.validate_encode_request(vmaf) == {:error, :missing_video_id}
    end
  end

  describe "build_crf_search_message/2" do
    test "builds correct message tuple" do
      video = %{id: 123, path: "/test.mkv"}
      result = QueueManager.build_crf_search_message(video, 95)
      assert result == {:crf_search, video, 95}
    end
  end

  describe "build_encode_message/1" do
    test "builds correct message tuple" do
      vmaf = %{id: 456, video_id: 123, crf: 28.0}
      result = QueueManager.build_encode_message(vmaf)
      assert result == {:encode, vmaf}
    end
  end
end
