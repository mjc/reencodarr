defmodule Reencodarr.AnalyzerTest do
  use Reencodarr.DataCase

  alias Reencodarr.Analyzer

  describe "analyzer GenStage pipeline" do
    test "process_path/1 adds video to pipeline" do
      video_info = %{
        path: "/test/video.mkv",
        service_id: "123",
        service_type: :sonarr,
        force_reanalyze: false
      }

      # This should not fail and should return :ok
      assert :ok == Analyzer.process_path(video_info)
    end

    test "process_path/1 handles force_reanalyze" do
      video_info = %{
        path: "/test/video.mkv",
        service_id: "123",
        service_type: :sonarr,
        force_reanalyze: true
      }

      # This should not fail and should return :ok
      assert :ok == Analyzer.process_path(video_info)
    end

    test "analyzer provides backward compatibility functions" do
      # These functions should exist and not crash
      assert is_boolean(Analyzer.running?())

      # In test environment, Broadway pipeline is not started by default
      # So these functions should return error tuples instead of crashing
      assert Analyzer.start() == {:error, :producer_supervisor_not_found}
      assert Analyzer.pause() == {:error, :producer_supervisor_not_found}

      # running? should return false when pipeline is not started
      assert Analyzer.running?() == false
    end
  end
end
