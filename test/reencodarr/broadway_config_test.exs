defmodule Reencodarr.BroadwayConfigTest do
  use ExUnit.Case, async: true

  alias Reencodarr.BroadwayConfig

  describe "merge_config/3" do
    test "merges configuration with proper precedence" do
      # Setup: default config and runtime options
      default_config = [rate_limit_messages: 10, batch_size: 1, timeout: 5000]
      opts = [batch_size: 3, new_option: "test"]

      # Mock app config
      Application.put_env(:reencodarr, TestModule, rate_limit_messages: 15, timeout: 8000)

      result = BroadwayConfig.merge_config(TestModule, default_config, opts)

      # Verify precedence: opts > app_config > default_config
      assert result[:rate_limit_messages] == 15  # from app config
      assert result[:batch_size] == 3           # from opts (highest priority)
      assert result[:timeout] == 8000           # from app config
      assert result[:new_option] == "test"      # from opts only

      # Cleanup
      Application.delete_env(:reencodarr, TestModule)
    end

    test "works with no app config" do
      default_config = [rate_limit_messages: 10, batch_size: 1]
      opts = [batch_size: 5]

      result = BroadwayConfig.merge_config(NonExistentModule, default_config, opts)

      assert result[:rate_limit_messages] == 10  # from default
      assert result[:batch_size] == 5           # from opts
    end

    test "works with empty opts" do
      default_config = [rate_limit_messages: 10, batch_size: 1]

      result = BroadwayConfig.merge_config(NonExistentModule, default_config, [])

      assert result == default_config
    end
  end

  describe "rate_limiting_config/1" do
    test "creates proper rate limiting configuration" do
      config = [rate_limit_messages: 5, rate_limit_interval: 2000]

      result = BroadwayConfig.rate_limiting_config(config)

      assert result == [allowed_messages: 5, interval: 2000]
    end

    test "handles missing values" do
      config = [rate_limit_messages: 3]

      result = BroadwayConfig.rate_limiting_config(config)

      assert result == [allowed_messages: 3, interval: nil]
    end
  end

  describe "processor_config/0" do
    test "returns standardized processor configuration" do
      result = BroadwayConfig.processor_config()

      assert result == [
        default: [
          concurrency: 1,
          max_demand: 1
        ]
      ]
    end
  end

  describe "crf_search_batcher_config/1" do
    test "creates proper CRF search batcher configuration" do
      config = [batch_size: 3, batch_timeout: 5000]

      result = BroadwayConfig.crf_search_batcher_config(config)

      assert result == [
        default: [
          batch_size: 3,
          batch_timeout: 5000
        ]
      ]
    end
  end

  describe "encoding_batcher_config/1" do
    test "creates proper encoding batcher configuration" do
      config = [batch_size: 1, batch_timeout: 10000]

      result = BroadwayConfig.encoding_batcher_config(config)

      assert result == [
        default: [
          batch_size: 1,
          batch_timeout: 10000
        ]
      ]
    end
  end
end
