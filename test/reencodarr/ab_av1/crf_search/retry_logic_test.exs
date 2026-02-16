defmodule Reencodarr.AbAv1.CrfSearch.RetryLogicTest do
  @moduledoc """
  Tests for CRF search retry logic with season-aware narrowed ranges.
  See crf_search_retry_refactor_test.exs for the full test suite.
  """
  use Reencodarr.DataCase, async: true

  alias Reencodarr.AbAv1.CrfSearch
  alias Reencodarr.CrfSearchHints

  describe "season-aware CRF range" do
    setup do
      {:ok, video} = Fixtures.video_fixture(%{path: "/test/retry_video.mkv", size: 2_000_000_000})
      %{video: video}
    end

    test "build_crf_search_args/3 respects crf_range option", %{video: video} do
      args = CrfSearch.build_crf_search_args(video, 95, crf_range: {14, 30})

      min_idx = Enum.find_index(args, &(&1 == "--min-crf"))
      max_idx = Enum.find_index(args, &(&1 == "--max-crf"))

      assert Enum.at(args, min_idx + 1) == "14"
      assert Enum.at(args, max_idx + 1) == "30"

      # Should include basic CRF search args
      assert "crf-search" in args
      assert video.path in args
      assert "--min-vmaf" in args
      assert "95" in args
    end

    test "build_crf_search_args/2 uses default range", %{video: video} do
      args = CrfSearch.build_crf_search_args(video, 95)

      min_idx = Enum.find_index(args, &(&1 == "--min-crf"))
      max_idx = Enum.find_index(args, &(&1 == "--max-crf"))

      assert Enum.at(args, min_idx + 1) == "8"
      assert Enum.at(args, max_idx + 1) == "40"
    end

    test "narrowed_range? detects non-default ranges" do
      assert CrfSearchHints.narrowed_range?({14, 30})
      assert CrfSearchHints.narrowed_range?({10, 40})
      assert CrfSearchHints.narrowed_range?({8, 35})
      refute CrfSearchHints.narrowed_range?({8, 40})
    end
  end
end
