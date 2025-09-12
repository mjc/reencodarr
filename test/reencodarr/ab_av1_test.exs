defmodule Reencodarr.AbAv1Test do
  use Reencodarr.UnitCase, async: true

  alias Reencodarr.AbAv1
  alias Reencodarr.AbAv1.QueueManager

  describe "crf_search/2 validation" do
    test "validates input and returns appropriate responses" do
      # Valid input should validate successfully
      video = %{id: 123, path: "/test.mkv"}

      # Test the validation logic directly instead of calling the GenServer
      assert QueueManager.validate_crf_search_request(video, 95) == {:ok, {video, 95}}
    end

    test "returns error for invalid video" do
      # Test validation directly
      assert QueueManager.validate_crf_search_request(nil, 95) == {:error, :invalid_video}
      assert QueueManager.validate_crf_search_request("not a map", 95) == {:error, :invalid_video}
    end

    test "returns error for invalid vmaf_percent" do
      video = %{id: 123, path: "/test.mkv"}

      # Test validation directly
      assert QueueManager.validate_crf_search_request(video, 150) ==
               {:error, :invalid_vmaf_percent}

      assert QueueManager.validate_crf_search_request(video, 30) ==
               {:error, :invalid_vmaf_percent}
    end
  end

  describe "encode/1 validation" do
    test "validates input and returns appropriate responses" do
      # Valid input should validate successfully
      vmaf = %{id: 456, video_id: 123, crf: 28.0}

      # Test the validation logic directly instead of calling the GenServer
      assert QueueManager.validate_encode_request(vmaf) == {:ok, vmaf}
    end

    test "returns error for invalid vmaf" do
      # Test validation directly
      assert QueueManager.validate_encode_request(nil) == {:error, :invalid_vmaf}
      assert QueueManager.validate_encode_request("not a map") == {:error, :invalid_vmaf}
    end

    test "returns error for vmaf without video_id" do
      vmaf = %{id: 456, crf: 28.0}

      # Test validation directly
      assert QueueManager.validate_encode_request(vmaf) == {:error, :missing_video_id}
    end
  end

  describe "queue_length/0" do
    test "returns queue length structure" do
      result = AbAv1.queue_length()
      assert is_map(result)
      assert Map.has_key?(result, :crf_searches)
      assert Map.has_key?(result, :encodes)
      assert is_integer(result.crf_searches)
      assert is_integer(result.encodes)
    end

    test "queue lengths are non-negative" do
      result = AbAv1.queue_length()
      assert result.crf_searches >= 0
      assert result.encodes >= 0
    end
  end
end
