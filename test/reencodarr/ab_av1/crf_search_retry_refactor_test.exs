defmodule Reencodarr.AbAv1.CrfSearchRetryRefactorTest do
  @moduledoc """
  Tests for the refactored CRF search retry mechanism.

  The retry strategy:
  1. First attempt uses season-aware narrowed CRF range (if siblings exist)
  2. If CRF search fails with a narrowed range, retry with standard range {5, 70}
  3. If CRF search fails with standard range, mark as failed (no more retries)
  4. Hard stop: if @max_crf_search_retries (3) unresolved failures already exist,
     skip retries entirely and mark as failed immediately.
  """
  use Reencodarr.DataCase, async: false
  @moduletag capture_log: true
  import ExUnit.CaptureLog

  alias Reencodarr.AbAv1.CrfSearch
  alias Reencodarr.AbAv1.CrfSearcher
  alias Reencodarr.AbAv1.Helper
  alias Reencodarr.CrfSearchHints
  alias Reencodarr.Media

  # Stop lingering CrfSearcher port-holder from previous tests so
  # recover_or_init_state/0 doesn't inherit stale current_task
  defp stop_crf_searcher do
    if pid = GenServer.whereis(CrfSearcher) do
      try do
        GenServer.stop(pid, :normal, 1000)
      catch
        :exit, _ -> :ok
      end

      Process.sleep(10)
    end
  end

  describe "build_crf_search_args/3 with CRF range option" do
    test "uses default range when no range option provided" do
      video = %{path: "/test/video.mkv"}
      args = CrfSearch.build_crf_search_args(video, 95)

      min_idx = Enum.find_index(args, &(&1 == "--min-crf"))
      max_idx = Enum.find_index(args, &(&1 == "--max-crf"))

      assert Enum.at(args, min_idx + 1) == "5"
      assert Enum.at(args, max_idx + 1) == "70"
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

  describe "current_task stores updated video state" do
    setup do
      try do
        :meck.unload()
      rescue
        _ -> :ok
      end

      stop_crf_searcher()

      on_exit(fn ->
        stop_crf_searcher()

        try do
          :meck.unload()
        rescue
          _ -> :ok
        end
      end)

      {:ok, pid} = CrfSearch.start_link([])

      on_exit(fn ->
        case GenServer.whereis(CrfSearch) do
          nil ->
            :ok

          crf_pid when is_pid(crf_pid) ->
            if Process.alive?(crf_pid) do
              try do
                GenServer.stop(crf_pid, :normal)
              catch
                :exit, _ -> :ok
              end
            else
              :ok
            end

          _ ->
            :ok
        end
      end)

      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/tv/Stale State/Season 01/Stale.State.S01E01.mkv",
          height: 1080,
          width: 1920,
          state: :analyzed
        })

      %{pid: pid, video: video}
    end

    test "video in current_task has crf_searching state after search starts", %{video: video} do
      fake_port = Port.open({:spawn, "cat"}, [:binary])
      :meck.new(Helper, [:passthrough])
      :meck.expect(Helper, :open_port, fn _args -> {:ok, fake_port} end)

      GenServer.cast(CrfSearch, {:crf_search, video, 95})
      Process.sleep(100)

      state = :sys.get_state(CrfSearch)
      assert state.current_task != :none
      # The stored video should reflect the DB state (crf_searching),
      # not the stale state from when the Producer dispatched it
      assert state.current_task.video.state == :crf_searching

      Port.close(fake_port)
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
      {min_crf, max_crf} = CrfSearchHints.crf_range(video, 95)
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
      {min_crf, max_crf} = CrfSearchHints.crf_range(video, 95, retry: true)
      assert {min_crf, max_crf} == {5, 70}

      args = CrfSearch.build_crf_search_args(video, 95, crf_range: {min_crf, max_crf})

      min_idx = Enum.find_index(args, &(&1 == "--min-crf"))
      max_idx = Enum.find_index(args, &(&1 == "--max-crf"))

      assert Enum.at(args, min_idx + 1) == "5"
      assert Enum.at(args, max_idx + 1) == "70"
    end
  end

  describe "GenServer retry behavior" do
    setup do
      try do
        :meck.unload()
      rescue
        _ -> :ok
      end

      stop_crf_searcher()

      on_exit(fn ->
        stop_crf_searcher()

        try do
          :meck.unload()
        rescue
          _ -> :ok
        end
      end)

      {:ok, pid} = CrfSearch.start_link([])

      on_exit(fn ->
        case GenServer.whereis(CrfSearch) do
          nil ->
            :ok

          crf_pid when is_pid(crf_pid) ->
            if Process.alive?(crf_pid) do
              try do
                GenServer.stop(crf_pid, :normal)
              catch
                :exit, _ -> :ok
              end
            else
              :ok
            end

          _ ->
            :ok
        end
      end)

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
      capture_log(fn ->
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

        :meck.expect(Reencodarr.Media, :mark_as_crf_searching, fn v ->
          {:ok, Map.put(v, :state, :crf_searching)}
        end)

        :meck.expect(Reencodarr.Media, :mark_as_failed, fn _v -> {:ok, %{}} end)

        :meck.expect(Reencodarr.Media, :mark_as_analyzed, fn v ->
          {:ok, Map.put(v, :state, :analyzed)}
        end)

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
        # Narrowed from sibling CRF 22 ± 6 → min should be > 5
        assert String.to_integer(first_min) > 5

        # Retry should have standard range
        retry_min_idx = Enum.find_index(retry_args, &(&1 == "--min-crf"))
        retry_max_idx = Enum.find_index(retry_args, &(&1 == "--max-crf"))
        assert Enum.at(retry_args, retry_min_idx + 1) == "5"
        assert Enum.at(retry_args, retry_max_idx + 1) == "70"
      end)
    end

    test "failure with standard range marks video as failed", %{pid: _pid} do
      capture_log(fn ->
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

        :meck.expect(Reencodarr.Media, :mark_as_crf_searching, fn v ->
          {:ok, Map.put(v, :state, :crf_searching)}
        end)

        :meck.expect(Reencodarr.Media, :mark_as_failed, fn _v ->
          send(test_pid, :marked_as_failed)
          {:ok, %{}}
        end)

        :meck.expect(Reencodarr.Media, :record_video_failure, fn _v, _s, _c, _o -> {:ok, %{}} end)

        GenServer.cast(CrfSearch, {:crf_search, lonely_video, 95})
        Process.sleep(500)

        # Should mark as failed (no retry since standard range was already used)
        assert_received :marked_as_failed
      end)
    end
  end
end
