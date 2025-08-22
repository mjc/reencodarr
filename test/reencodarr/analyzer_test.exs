defmodule Reencodarr.AnalyzerTest do
  use Reencodarr.DataCase
  import ExUnit.CaptureLog

  alias Reencodarr.Analyzer

  describe "analyzer public API (unit tests)" do
    test "process_path/1 returns :ok for valid input when Broadway is not available" do
      valid_input = %{
        path: "/test/video.mkv",
        service_id: "123",
        service_type: :sonarr,
        force_reanalyze: false
      }

      capture_log(fn ->
        assert :ok == Analyzer.process_path(valid_input)
      end)
    end

    test "process_path/1 handles missing Broadway gracefully" do
      video_info = %{
        path: "/test/video.mkv",
        service_id: "123",
        service_type: :sonarr,
        force_reanalyze: true
      }

      # This should not fail and should return :ok even when Broadway is not available
      assert :ok == Analyzer.process_path(video_info)
    end
  end

  describe "analyzer backward compatibility API (integration tests)" do
    @tag :integration
    test "analyzer provides backward compatibility functions" do
      capture_log(fn ->
        # These functions should exist and not crash
        assert is_boolean(Analyzer.running?())

        # In test environment, Broadway pipeline is not started by default
        # So these functions should return error tuples instead of crashing
        assert Analyzer.start() == {:error, :producer_supervisor_not_found}
        assert Analyzer.pause() == {:error, :producer_supervisor_not_found}

        # running? should return false when pipeline is not started
        assert Analyzer.running?() == false
      end)
    end
  end
end
