defmodule Reencodarr.AbAv1.CrfSearchVmafRetryTest do
  @moduledoc """
  Tests for VMAF target reduction retry.

  When a CRF search fails because the target VMAF is unreachable (even at CRF 8),
  the system retries with a 1-point lower target — but only after exhausting the
  narrowed → standard range retry first.

  Retry cascade:
    1. narrowed range + original target  → retry with standard range {8,40} + same target
    2. standard range + original target  → retry with standard range {8,40} + target - 1
    3. standard range + reduced target   → final failure
  """
  use Reencodarr.DataCase, async: false
  @moduletag capture_log: true
  import ExUnit.CaptureLog

  alias Reencodarr.AbAv1.CrfSearch
  alias Reencodarr.AbAv1.Helper
  alias Reencodarr.Media
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

    :meck.expect(Reencodarr.Media, :mark_as_analyzed, fn _v -> {:ok, %{}} end)

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

      # No siblings → standard range {8, 40} used on first attempt
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

    test "retries with target - 1 on CRF optimization error", %{video: video} do
      capture_log(fn ->
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
        assert_received {:open_port_call, 2, retry_args}
        assert find_arg(retry_args, "--min-vmaf") == Integer.to_string(original_target - 1)
        assert find_arg(retry_args, "--min-crf") == "5"
        assert find_arg(retry_args, "--max-crf") == "70"

        # Second attempt fails → final failure (target already reduced)
        assert_received :marked_as_failed
        refute_received {:open_port_call, 3, _}
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
        test_pid = self()
        reduced_target = Rules.min_vmaf_target(video)
        _call_count = mock_port_failure(test_pid)

        GenServer.cast(CrfSearch, {:crf_search, video, reduced_target})
        Process.sleep(800)

        # Only one call — no retry
        assert_received {:open_port_call, 1, _args}
        assert_received :marked_as_failed
        refute_received {:open_port_call, 2, _}
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

      {:ok, _vmaf} =
        Media.create_vmaf(%{
          video_id: sibling.id,
          crf: 22.0,
          score: 95.0,
          chosen: true,
          params: ["--preset", "4"]
        })

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

        # Third attempt fails → final failure (target already reduced)
        assert_received :marked_as_failed
        refute_received {:open_port_call, 4, _}
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
