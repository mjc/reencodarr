defmodule Reencodarr.AbAv1.CrfSearchVmafRetryTest do
  @moduledoc """
  Tests for VMAF target reduction retry.

  When a CRF search fails because the target VMAF is unreachable (even at minimum CRF),
  the system retries with a 1-point lower target — but only after exhausting the
  narrowed → standard range retry first, and only if the retry limit has not been reached.

  Retry cascade:
    1. narrowed range + original target  → retry with standard range {5,70} + same target
    2. standard range + original target  → retry with standard range {5,70} + target - 1
    3. standard range + reduced target   → retry with standard range {5,70} + target - 2
    4. standard range + minimum target   → final failure

  Hard stop: when @max_crf_search_retries (3) unresolved crf_search failures already
  exist for the video, any further failure immediately records a final failure and
  marks the video as failed — no retry regardless of range or target.
  """
  use Reencodarr.DataCase, async: false
  @moduletag capture_log: true
  import ExUnit.CaptureLog

  alias Reencodarr.AbAv1.CrfSearch
  alias Reencodarr.AbAv1.CrfSearcher
  alias Reencodarr.AbAv1.Helper
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Media
  alias Reencodarr.Media.VideoFailure
  alias Reencodarr.Rules

  require Logger

  @crf_error_line "Error: Failed to find a suitable crf"

  # Helpers

  defp find_arg(args, flag) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> nil
      idx -> Enum.at(args, idx + 1)
    end
  end

  defp stop_genserver do
    # Stop the CrfSearcher port-holder first, otherwise the new
    # CrfSearch GenServer will recover its state via recover_or_init_state/0
    if searcher_pid = GenServer.whereis(CrfSearcher) do
      try do
        GenServer.stop(searcher_pid, :normal, 1000)
      catch
        :exit, _ -> :ok
      end

      Process.sleep(10)
    end

    if pid = GenServer.whereis(CrfSearch) do
      try do
        GenServer.stop(pid, :normal, 1000)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp setup_meck do
    try do
      :meck.unload()
    rescue
      _ -> :ok
    end

    stop_genserver()

    on_exit(fn ->
      stop_genserver()

      try do
        :meck.unload()
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end)
  end

  defp mock_port_failure(test_pid, opts \\ []) do
    call_count = :counters.new(1, [:atomics])
    output_lines = Keyword.get(opts, :output_lines, [@crf_error_line])

    :meck.new(Helper, [:passthrough])

    :meck.expect(Helper, :open_port, fn args ->
      :counters.add(call_count, 1, 1)
      count = :counters.get(call_count, 1)
      send(test_pid, {:open_port_call, count, args})

      # Spawn a script that outputs lines then exits with failure
      script = Enum.map_join(output_lines, "; ", &"echo '#{&1}'") <> "; exit 1"
      port = Port.open({:spawn, "sh -c \"#{script}\""}, [:exit_status, :binary, {:line, 1024}])
      {:ok, port}
    end)

    :meck.new(Reencodarr.Media, [:passthrough])

    :meck.expect(Reencodarr.Media, :mark_as_crf_searching, fn v ->
      {:ok, Map.put(v, :state, :crf_searching)}
    end)

    :meck.expect(Reencodarr.Media, :mark_as_analyzed, fn v ->
      {:ok, Map.put(v, :state, :analyzed)}
    end)

    :meck.expect(Reencodarr.Media, :mark_as_failed, fn _v ->
      send(test_pid, :marked_as_failed)
      {:ok, %{}}
    end)

    :meck.expect(Reencodarr.Media, :record_video_failure, fn _v, _s, _c, _o -> {:ok, %{}} end)

    call_count
  end

  describe "handle_error_line does not mark video as failed" do
    setup do
      setup_meck()

      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/movies/error_test.mkv",
          state: :crf_searching,
          size: 2_147_483_648
        })

      %{video: video}
    end

    test "process_line with error string does not mark video failed", %{video: video} do
      CrfSearch.process_line(@crf_error_line, video, [], 95)

      reloaded = Repo.get(Media.Video, video.id)
      refute reloaded.state == :failed
    end
  end

  describe "standard range failure retries with reduced target" do
    setup do
      setup_meck()
      {:ok, _pid} = CrfSearch.start_link([])

      on_exit(fn ->
        case GenServer.whereis(CrfSearch) do
          nil ->
            :ok

          crf_pid when is_pid(crf_pid) ->
            try do
              if Process.alive?(crf_pid), do: GenServer.stop(crf_pid, :normal, 1000), else: :ok
            catch
              :exit, _ -> :ok
            end

          _ ->
            :ok
        end
      end)

      # No siblings → standard range {5, 70} used on first attempt
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/movies/vmaf_retry_test.mkv",
          height: 1080,
          width: 1920,
          state: :analyzed,
          size: 2_147_483_648
        })

      %{video: video}
    end

    test "keeps lowering target until min_vmaf_target on CRF optimization error", %{video: video} do
      capture_log(fn ->
        Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())
        test_pid = self()
        original_target = Rules.vmaf_target(video)
        _call_count = mock_port_failure(test_pid)

        GenServer.cast(CrfSearch, {:crf_search, video, original_target})
        Process.sleep(1500)

        # First call: standard range, original target
        assert_received {:open_port_call, 1, first_args}
        assert find_arg(first_args, "--min-vmaf") == Integer.to_string(original_target)
        assert find_arg(first_args, "--min-crf") == "5"
        assert find_arg(first_args, "--max-crf") == "70"

        # Second call: standard range, reduced target
        assert_received {:crf_search_completed,
                         %{video_id: video_id, result: {:retry, retry_target}}}

        assert video_id == video.id
        assert retry_target == original_target - 1

        assert_received {:open_port_call, 2, retry_args}
        assert find_arg(retry_args, "--min-vmaf") == Integer.to_string(original_target - 1)
        assert find_arg(retry_args, "--min-crf") == "5"
        assert find_arg(retry_args, "--max-crf") == "70"

        # Third call: standard range, minimum reduced target
        assert_received {:open_port_call, 3, min_target_args}
        assert find_arg(min_target_args, "--min-vmaf") == Integer.to_string(original_target - 2)
        assert find_arg(min_target_args, "--min-crf") == "5"
        assert find_arg(min_target_args, "--max-crf") == "70"

        # Third attempt fails → final failure (target is at min_vmaf_target)
        assert_received :marked_as_failed
        refute_received {:open_port_call, 4, _}
      end)
    end
  end

  describe "already-reduced target marks as final failure" do
    setup do
      setup_meck()
      {:ok, _pid} = CrfSearch.start_link([])

      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/movies/already_reduced.mkv",
          height: 1080,
          width: 1920,
          state: :analyzed,
          size: 2_147_483_648
        })

      %{video: video}
    end

    test "no retry when target is already below vmaf_target", %{video: video} do
      capture_log(fn ->
        Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())
        test_pid = self()
        reduced_target = Rules.min_vmaf_target(video)
        _call_count = mock_port_failure(test_pid)

        GenServer.cast(CrfSearch, {:crf_search, video, reduced_target})
        Process.sleep(800)

        # Only one call — no retry
        assert_received {:open_port_call, 1, _args}
        assert_received :marked_as_failed
        assert_received {:crf_search_completed, %{video_id: video_id, result: {:error, :failed}}}
        assert video_id == video.id
        refute_received {:open_port_call, 2, _}
      end)
    end
  end

  describe "successful CRF search without a chosen VMAF" do
    setup do
      setup_meck()

      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/movies/auto_choose_vmaf.mkv",
          height: 1080,
          width: 1920,
          state: :crf_searching,
          size: 2_147_483_648
        })

      %{video: video}
    end

    test "auto-selects the best VMAF and marks the video crf_searched", %{video: video} do
      target = Rules.vmaf_target(video)

      larger_vmaf =
        Fixtures.vmaf_fixture(%{
          video_id: video.id,
          crf: 18.0,
          score: target + 1.0,
          percent: 82.0
        })

      smaller_qualifying_vmaf =
        Fixtures.vmaf_fixture(%{
          video_id: video.id,
          crf: 22.0,
          score: target * 1.0,
          percent: 74.0
        })

      Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())

      state = %{
        current_task: %{video: video, args: [], target_vmaf: target, crf_range: {5, 70}},
        partial_line_buffer: "",
        output_buffer: [],
        searcher_monitor: nil,
        os_pid: nil
      }

      assert {:noreply, clean_state} =
               CrfSearch.handle_info({CrfSearcher, {:exit_status, 0}}, state)

      assert clean_state.current_task == :none

      reloaded = Repo.get!(Media.Video, video.id)
      assert reloaded.state == :crf_searched
      assert reloaded.chosen_vmaf_id == smaller_qualifying_vmaf.id
      refute reloaded.chosen_vmaf_id == larger_vmaf.id

      assert_received {:crf_search_completed, %{video_id: video_id, result: :ok}}
      assert video_id == video.id
    end

    test "marks failed and broadcasts an error when success produced no VMAFs", %{video: video} do
      Phoenix.PubSub.subscribe(Reencodarr.PubSub, Events.channel())

      state = %{
        current_task: %{
          video: video,
          args: [],
          target_vmaf: Rules.vmaf_target(video),
          crf_range: {5, 70}
        },
        partial_line_buffer: "",
        output_buffer: [],
        searcher_monitor: nil,
        os_pid: nil
      }

      assert {:noreply, clean_state} =
               CrfSearch.handle_info({CrfSearcher, {:exit_status, 0}}, state)

      assert clean_state.current_task == :none

      assert Repo.get!(Media.Video, video.id).state == :failed

      assert_received {:crf_search_completed,
                       %{video_id: video_id, result: {:error, :no_vmaf_results}}}

      assert video_id == video.id
    end
  end

  describe "partially reduced target retries again" do
    setup do
      setup_meck()
      {:ok, _pid} = CrfSearch.start_link([])

      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/movies/partially_reduced.mkv",
          height: 1080,
          width: 1920,
          state: :analyzed,
          size: 2_147_483_648
        })

      # Simulates a previous 95 -> 94 retry marker still being present.
      {:ok, _failure} =
        VideoFailure.record_failure(video, :crf_search, :vmaf_calculation,
          code: "VMAF_CALC",
          message: "Prior target reduction retry marker"
        )

      %{video: video}
    end

    test "target 94 can still retry to target 93 when retry budget remains", %{video: video} do
      capture_log(fn ->
        test_pid = self()
        original_target = Rules.vmaf_target(video)
        partially_reduced_target = original_target - 1
        _call_count = mock_port_failure(test_pid)

        GenServer.cast(CrfSearch, {:crf_search, video, partially_reduced_target})
        Process.sleep(1200)

        assert_received {:open_port_call, 1, first_args}
        assert find_arg(first_args, "--min-vmaf") == Integer.to_string(partially_reduced_target)
        assert find_arg(first_args, "--min-crf") == "5"
        assert find_arg(first_args, "--max-crf") == "70"

        assert_received {:open_port_call, 2, retry_args}
        assert find_arg(retry_args, "--min-vmaf") == Integer.to_string(original_target - 2)
        assert find_arg(retry_args, "--min-crf") == "5"
        assert find_arg(retry_args, "--max-crf") == "70"

        assert_received :marked_as_failed
        refute_received {:open_port_call, 3, _}
      end)
    end
  end

  describe "narrowed range retry takes precedence" do
    setup do
      setup_meck()
      {:ok, _pid} = CrfSearch.start_link([])

      # Video with sibling → narrowed range
      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/tv/Retry VMAF/Season 01/Retry.VMAF.S01E02.mkv",
          height: 1080,
          width: 1920,
          state: :analyzed,
          size: 2_147_483_648
        })

      {:ok, sibling} =
        Fixtures.video_fixture(%{
          path: "/tv/Retry VMAF/Season 01/Retry.VMAF.S01E01.mkv",
          height: 1080,
          width: 1920,
          state: :crf_searched
        })

      {:ok, sibling_vmaf} =
        Media.create_vmaf(%{
          video_id: sibling.id,
          crf: 22.0,
          score: 95.0,
          params: ["--preset", "4"]
        })

      Fixtures.choose_vmaf(sibling, sibling_vmaf)

      %{video: video, sibling: sibling}
    end

    test "first retry uses standard range with same target, then reduces", %{video: video} do
      capture_log(fn ->
        test_pid = self()
        original_target = Rules.vmaf_target(video)
        _call_count = mock_port_failure(test_pid)

        GenServer.cast(CrfSearch, {:crf_search, video, original_target})
        Process.sleep(2000)

        # Call 1: narrowed range, original target
        assert_received {:open_port_call, 1, first_args}
        first_min = find_arg(first_args, "--min-crf")
        assert String.to_integer(first_min) > 5
        assert find_arg(first_args, "--min-vmaf") == Integer.to_string(original_target)

        # Call 2: standard range, same target (narrowed retry)
        assert_received {:open_port_call, 2, standard_args}
        assert find_arg(standard_args, "--min-crf") == "5"
        assert find_arg(standard_args, "--max-crf") == "70"
        assert find_arg(standard_args, "--min-vmaf") == Integer.to_string(original_target)

        # Call 3: standard range, reduced target
        assert_received {:open_port_call, 3, reduced_args}
        assert find_arg(reduced_args, "--min-crf") == "5"
        assert find_arg(reduced_args, "--max-crf") == "70"
        assert find_arg(reduced_args, "--min-vmaf") == Integer.to_string(original_target - 1)

        # Call 4: standard range, minimum reduced target
        assert_received {:open_port_call, 4, min_target_args}
        assert find_arg(min_target_args, "--min-crf") == "5"
        assert find_arg(min_target_args, "--max-crf") == "70"
        assert find_arg(min_target_args, "--min-vmaf") == Integer.to_string(original_target - 2)

        # Fourth attempt fails → final failure (target is at min_vmaf_target)
        assert_received :marked_as_failed
        refute_received {:open_port_call, 5, _}
      end)
    end
  end

  describe "max retry count prevents infinite loop" do
    setup do
      setup_meck()
      {:ok, _pid} = CrfSearch.start_link([])

      on_exit(fn ->
        case GenServer.whereis(CrfSearch) do
          nil ->
            :ok

          crf_pid when is_pid(crf_pid) ->
            try do
              if Process.alive?(crf_pid), do: GenServer.stop(crf_pid, :normal, 1000), else: :ok
            catch
              :exit, _ -> :ok
            end

          _ ->
            :ok
        end
      end)

      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/movies/max_retry_test.mkv",
          height: 1080,
          width: 1920,
          state: :analyzed,
          size: 2_147_483_648
        })

      # Pre-seed @max_crf_search_retries (3) unresolved crf_search failures using
      # VideoFailure.record_failure directly — avoids the state transition that
      # Media.record_video_failure would trigger (which also calls mark_as_failed).
      # This simulates the state that caused video 11917998's infinite loop.
      for i <- 1..3 do
        {:ok, _} =
          VideoFailure.record_failure(video, :crf_search, :vmaf_calculation,
            code: "VMAF_CALC",
            message: "Prior loop failure #{i}"
          )
      end

      %{video: video}
    end

    test "goes straight to final failure when retry limit already reached", %{video: video} do
      capture_log(fn ->
        test_pid = self()
        _call_count = mock_port_failure(test_pid)

        GenServer.cast(CrfSearch, {:crf_search, video, 95})
        Process.sleep(800)

        # One port call to start the search
        assert_received {:open_port_call, 1, _args}

        # Immediately final-failures — no retry despite CRF error and narrowed range
        assert_received :marked_as_failed
        refute_received {:open_port_call, 2, _}
      end)
    end

    test "retry limit is checked before range/target logic", %{video: video} do
      # With siblings in scope, the first attempt would normally use a narrowed range.
      # Even with a narrowed range (which previously always triggered retry_wider_range),
      # the limit check fires first and stops any retry.
      {:ok, sibling} =
        Fixtures.video_fixture(%{
          path: "/tv/Loop Show/Season 01/Loop.Show.S01E01.mkv",
          height: 1080,
          width: 1920,
          state: :crf_searched
        })

      {:ok, sibling_vmaf} =
        Media.create_vmaf(%{
          video_id: sibling.id,
          crf: 22.0,
          score: 95.0,
          params: ["--preset", "4"]
        })

      Fixtures.choose_vmaf(sibling, sibling_vmaf)

      capture_log(fn ->
        test_pid = self()
        _call_count = mock_port_failure(test_pid)

        # Override the video path so it shares the season dir with the sibling
        narrowed_video = %{video | path: "/tv/Loop Show/Season 01/Loop.Show.S01E02.mkv"}
        GenServer.cast(CrfSearch, {:crf_search, narrowed_video, 95})
        Process.sleep(800)

        assert_received {:open_port_call, 1, _args}
        assert_received :marked_as_failed
        refute_received {:open_port_call, 2, _}
      end)
    end
  end

  describe "non-CRF-error failures don't trigger target reduction" do
    setup do
      setup_meck()
      {:ok, _pid} = CrfSearch.start_link([])

      {:ok, video} =
        Fixtures.video_fixture(%{
          path: "/test/movies/non_crf_error.mkv",
          height: 1080,
          width: 1920,
          state: :analyzed,
          size: 2_147_483_648
        })

      %{video: video}
    end

    @tag :flaky
    test "port crash without CRF error line goes to final failure", %{video: video} do
      capture_log(fn ->
        test_pid = self()
        original_target = Rules.vmaf_target(video)

        # Output doesn't contain the CRF optimization error
        _call_count = mock_port_failure(test_pid, output_lines: ["Some random error"])

        GenServer.cast(CrfSearch, {:crf_search, video, original_target})
        Process.sleep(800)

        # Only one attempt — no retry since it's not a CRF optimization error
        assert_received {:open_port_call, 1, _args}
        assert_received :marked_as_failed
        refute_received {:open_port_call, 2, _}
      end)
    end
  end
end
