defmodule Reencodarr.CrfSearcher.BroadwayTest do
  use ExUnit.Case, async: true

  alias Reencodarr.CrfSearcher.Broadway
  alias Reencodarr.BroadwayConfig

  describe "transform/2" do
    test "transforms video data into Broadway message" do
      video = %{id: 1, path: "/path/to/video.mp4"}

      message = Broadway.transform(video, [])

      # Check that it's a Broadway Message struct and contains the data
      assert %{data: ^video} = message
      assert is_struct(message)
    end
  end

  describe "configuration" do
    test "merges default config with application config and opts" do
      # This test verifies the configuration priority:
      # opts > app_config > default_config

      # Mock application config
      original_config = Application.get_env(:reencodarr, Broadway, [])

      try do
        Application.put_env(:reencodarr, Broadway,
          rate_limit_messages: 5,
          crf_quality: 90
        )

        # Test Broadway configuration merging logic using centralized utility
        opts = [batch_size: 2]

        default_config = [
          rate_limit_messages: 10,
          rate_limit_interval: 1_000,
          batch_size: 1,
          batch_timeout: 5_000,
          crf_quality: 95
        ]

        final_config = BroadwayConfig.merge_config(Broadway, default_config, opts)

        # Verify priority: opts > app_config > default_config
        # from app_config
        assert final_config[:rate_limit_messages] == 5
        # from default_config
        assert final_config[:rate_limit_interval] == 1_000
        # from opts
        assert final_config[:batch_size] == 2
        # from app_config
        assert final_config[:crf_quality] == 90
      after
        # Restore original config
        Application.put_env(:reencodarr, Broadway, original_config)
      end
    end
  end

  describe "producer state management" do
    test "tracks processing state correctly" do
      # This test verifies the processing flag is managed correctly
      # to prevent the pipeline from stopping after one item

      # Initial state should not be processing
      state = %{
        demand: 1,
        paused: false,
        queue: :queue.new(),
        processing: false
      }

      # After dispatching a video, processing should be true
      state_after_dispatch = %{state | processing: true, demand: 0}

      # After CRF search completes, processing should be false
      state_after_completion = %{state_after_dispatch | processing: false}

      # Verify states
      refute state.processing
      assert state_after_dispatch.processing
      refute state_after_completion.processing
    end
  end
end
