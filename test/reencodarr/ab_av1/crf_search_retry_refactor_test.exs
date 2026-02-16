defmodule Reencodarr.AbAv1.CrfSearchRetryRefactorTest do
  @moduledoc """
  Tests for the refactored CRF search retry mechanism.

  The new retry strategy:
  1. First attempt uses season-aware narrowed CRF range (if siblings exist)
  2. If CRF search fails with a narrowed range, retry with standard range {8, 40}
  3. If CRF search fails with standard range, mark as failed (no more retries)
  """
  use Reencodarr.DataCase, async: false

  alias Reencodarr.AbAv1.CrfSearch
  alias Reencodarr.AbAv1.Helper
  alias Reencodarr.CrfSearchHints
  alias Reencodarr.Media

  describe "build_crf_search_args/3 with CRF range option" do
    test "uses default range when no range option provided" do
      video = %{path: "/test/video.mkv"}
      args = CrfSearch.build_crf_search_args(video, 95)

      min_idx = Enum.find_index(args, &(&1 == "--min-crf"))
      max_idx = Enum.find_index(args, &(&1 == "--max-crf"))

      assert Enum.at(args, min_idx + 1) == "8"
      assert Enum.at(args, max_idx + 1) == "40"
    end

    test "uses provided CRF range from options" do
      video = %{path: "/test/video.mkv"}
      args = CrfSearch.build_crf_search_args(video, 95, crf_range: {14, 30})

      min_idx = Enum.find_index(args, &(&1 == "--min-crf"))
      max_idx = Enum.find_index(args, &(&1 == "--max-crf"))

      assert Enum.at(args, min_idx + 1) == "14"
      assert Enum.at(args, max_idx + 1) == "30"
    end

    test "backward compatible - 2-arity version still works" do
      video = %{path: "/test/video.mkv"}
      args = CrfSearch.build_crf_search_args(video, 95)

      assert "crf-search" in args
      assert "--min-crf" in args
      assert "--max-crf" in args
    end
  end

  describe "retry on failure with narrowed range" do
    setup do
      try do
        :meck.unload()
      rescue
        _ -> :ok
      end

      on_exit(fn ->
        try do
          :meck.unload()
        rescue
          _ -> :ok
        end
      end)

      # Create a test video
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/tv/Test Show/Season 01/Test.Show.S01E02.mkv",
          height: 1080,
          width: 1920,
          state: :analyzed
        })

      # Create a sibling with a chosen VMAF so hints will narrow the range
      {:ok, sibling} =
        Fixtures.video_fixture(%{
          path: "/tv/Test Show/Season 01/Test.Show.S01E01.mkv",
          height: 1080,
          width: 1920,
          state: :crf_searched
        })

      {:ok, _vmaf} =
        Media.create_vmaf(%{
          video_id: sibling.id,
          crf: 20.0,
          score: 95.0,
          chosen: true,
          params: ["--preset", "4"]
        })

      %{video: video, sibling: sibling}
    end

    test "first attempt uses narrowed range from siblings", %{video: video} do
      # Verify hints return a narrowed range
      {min_crf, max_crf} = CrfSearchHints.crf_range(video)
      assert CrfSearchHints.narrowed_range?({min_crf, max_crf})

      # Build args with the hint
      args = CrfSearch.build_crf_search_args(video, 95, crf_range: {min_crf, max_crf})

      min_idx = Enum.find_index(args, &(&1 == "--min-crf"))
      max_idx = Enum.find_index(args, &(&1 == "--max-crf"))

      assert Enum.at(args, min_idx + 1) == to_string(min_crf)
      assert Enum.at(args, max_idx + 1) == to_string(max_crf)
    end

    test "retry uses standard range", %{video: video} do
      # On retry, crf_range should return default
      {min_crf, max_crf} = CrfSearchHints.crf_range(video, retry: true)
      assert {min_crf, max_crf} == {8, 40}

      args = CrfSearch.build_crf_search_args(video, 95, crf_range: {min_crf, max_crf})

      min_idx = Enum.find_index(args, &(&1 == "--min-crf"))
      max_idx = Enum.find_index(args, &(&1 == "--max-crf"))

      assert Enum.at(args, min_idx + 1) == "8"
      assert Enum.at(args, max_idx + 1) == "40"
    end
  end

  describe "GenServer retry behavior" do
    setup do
      try do
        :meck.unload()
      rescue
        _ -> :ok
      end

      on_exit(fn ->
        try do
          :meck.unload()
        rescue
          _ -> :ok
        end
      end)

      {:ok, pid} = CrfSearch.start_link([])

      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/tv/Retry Show/Season 01/Retry.Show.S01E02.mkv",
          height: 1080,
          width: 1920,
          state: :analyzed
        })

      # Create sibling for narrowed range
      {:ok, sibling} =
        Fixtures.video_fixture(%{
          path: "/tv/Retry Show/Season 01/Retry.Show.S01E01.mkv",
          height: 1080,
          width: 1920,
          state: :crf_searched
        })

      {:ok, _vmaf} =
        Media.create_vmaf(%{
          video_id: sibling.id,
          crf: 22.0,
          score: 95.0,
          chosen: true,
          params: ["--preset", "4"]
        })

      %{pid: pid, video: video, sibling: sibling}
    end

    test "failure with narrowed range triggers retry with standard range", %{video: video} do
      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      :meck.new(Helper, [:passthrough])

      :meck.expect(Helper, :open_port, fn args ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        # First call: succeed to start the search, then we'll trigger failure via exit
        # Second call (retry): capture the args to verify standard range
        send(test_pid, {:open_port_call, count, args})

        # Open a process that immediately exits with non-zero status
        port = Port.open({:spawn, "false"}, [:exit_status, :binary, {:line, 1024}])
        {:ok, port}
      end)

      :meck.new(Reencodarr.Media, [:passthrough])
      :meck.expect(Reencodarr.Media, :mark_as_crf_searching, fn _v -> {:ok, %{}} end)
      :meck.expect(Reencodarr.Media, :mark_as_failed, fn _v -> {:ok, %{}} end)
      :meck.expect(Reencodarr.Media, :mark_as_analyzed, fn _v -> {:ok, %{}} end)

      :meck.expect(Reencodarr.Media, :record_video_failure, fn _v, _s, _c, _o -> {:ok, %{}} end)

      # Trigger the CRF search
      GenServer.cast(CrfSearch, {:crf_search, video, 95})

      # Wait for both attempts
      Process.sleep(500)

      # Should have been called twice - first with narrowed range, second with standard
      assert_received {:open_port_call, 1, first_args}
      assert_received {:open_port_call, 2, retry_args}

      # First attempt should have narrowed range
      first_min_idx = Enum.find_index(first_args, &(&1 == "--min-crf"))
      first_min = Enum.at(first_args, first_min_idx + 1)
      # Narrowed from sibling CRF 22 ± 6 → min should be > 8
      assert String.to_integer(first_min) > 8

      # Retry should have standard range
      retry_min_idx = Enum.find_index(retry_args, &(&1 == "--min-crf"))
      retry_max_idx = Enum.find_index(retry_args, &(&1 == "--max-crf"))
      assert Enum.at(retry_args, retry_min_idx + 1) == "8"
      assert Enum.at(retry_args, retry_max_idx + 1) == "40"
    end

    test "failure with standard range marks video as failed", %{pid: _pid} do
      test_pid = self()

      # Create video with NO siblings (so standard range is used)
      {:ok, lonely_video} =
        Fixtures.video_fixture(%{
          path: "/tv/Lonely Show/Season 01/Lonely.Show.S01E01.mkv",
          height: 1080,
          width: 1920,
          state: :analyzed
        })

      :meck.new(Helper, [:passthrough])

      :meck.expect(Helper, :open_port, fn _args ->
        port = Port.open({:spawn, "false"}, [:exit_status, :binary, {:line, 1024}])
        {:ok, port}
      end)

      :meck.new(Reencodarr.Media, [:passthrough])
      :meck.expect(Reencodarr.Media, :mark_as_crf_searching, fn _v -> {:ok, %{}} end)

      :meck.expect(Reencodarr.Media, :mark_as_failed, fn _v ->
        send(test_pid, :marked_as_failed)
        {:ok, %{}}
      end)

      :meck.expect(Reencodarr.Media, :record_video_failure, fn _v, _s, _c, _o -> {:ok, %{}} end)

      GenServer.cast(CrfSearch, {:crf_search, lonely_video, 95})
      Process.sleep(500)

      # Should mark as failed (no retry since standard range was already used)
      assert_received :marked_as_failed
    end
  end
end
