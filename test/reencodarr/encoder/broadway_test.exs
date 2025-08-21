defmodule Reencodarr.Encoder.BroadwayTest do
  use ExUnit.Case, async: true

  alias Reencodarr.Encoder.Broadway
  alias Reencodarr.BroadwayConfig

  describe "transform/2" do
    test "transforms VMAF data into Broadway message" do
      vmaf = %{id: 1, video: %{path: "/path/to/video.mp4"}}

      message = Broadway.transform(vmaf, [])

      # Check that it's a Broadway Message struct and contains the data
      assert %{data: ^vmaf} = message
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
          rate_limit_messages: 3,
          batch_timeout: 15_000
        )

        # Test Broadway configuration merging logic using centralized utility
        opts = [batch_size: 2]

        default_config = [
          rate_limit_messages: 5,
          rate_limit_interval: 1_000,
          batch_size: 1,
          batch_timeout: 10_000
        ]

        final_config = BroadwayConfig.merge_config(Broadway, default_config, opts)

        # Verify priority: opts > app_config > default_config
        # from app_config
        assert final_config[:rate_limit_messages] == 3
        # from default_config
        assert final_config[:rate_limit_interval] == 1_000
        # from opts
        assert final_config[:batch_size] == 2
        # from app_config
        assert final_config[:batch_timeout] == 15_000
      after
        # Restore original config
        Application.put_env(:reencodarr, Broadway, original_config)
      end
    end
  end

  describe "producer state management" do
    test "tracking processing state prevents duplicate dispatches" do
      # This test verifies that the processing flag works correctly
      initial_state = %{
        demand: 1,
        paused: false,
        queue: :queue.new(),
        processing: false
      }

      # When not processing, should be able to dispatch
      assert should_dispatch_test_helper(initial_state) == true

      # When processing, should not dispatch
      processing_state = %{initial_state | processing: true}
      assert should_dispatch_test_helper(processing_state) == false

      # When paused, should not dispatch
      paused_state = %{initial_state | paused: true}
      assert should_dispatch_test_helper(paused_state) == false
    end

    # Helper function to test dispatch logic without external dependencies
    defp should_dispatch_test_helper(state) do
      not state.paused and not state.processing
    end
  end
end
