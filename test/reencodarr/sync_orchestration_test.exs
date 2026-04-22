defmodule Reencodarr.SyncOrchestrationTest do
  use Reencodarr.DataCase, async: false

  import ExUnit.CaptureLog

  alias Reencodarr.{Media, Sync}

  @sync_env_keys [
    :sync_batch_size,
    :sync_write_batch_size,
    :sync_file_batch_size,
    :sync_fetch_concurrency,
    :sync_fetch_timeout_ms
  ]

  setup do
    old_env = Map.new(@sync_env_keys, &{&1, Application.get_env(:reencodarr, &1, :unset)})
    Enum.each(@sync_env_keys, &Application.delete_env(:reencodarr, &1))

    :meck.unload()

    on_exit(fn ->
      restore_env(old_env)
      :meck.unload()
    end)

    library = Fixtures.library_fixture(%{path: "/test"})
    %{library: library}
  end

  describe "sync_episodes orchestration" do
    test "fetches shows, fetches files per show, and creates videos" do
      test_pid = self()

      refute function_exported?(Reencodarr.Services, :get_all_episode_files, 0)

      mock_analyzer_dispatch(test_pid)
      :meck.new(Reencodarr.Services, [:passthrough])

      :meck.expect(Reencodarr.Services, :get_shows, fn ->
        send(test_pid, :shows_called)
        {:ok, %Req.Response{status: 200, body: [%{"id" => 1}, %{"id" => 2}]}}
      end)

      :meck.expect(Reencodarr.Services, :get_episode_files, fn series_id ->
        send(test_pid, {:per_series_called, series_id})

        {:ok,
         %Req.Response{
           status: 200,
           body: [service_file("/test/shows/series_#{series_id}.mkv", series_id)]
         }}
      end)

      capture_log(fn ->
        assert {:noreply, %{}} = Sync.handle_cast(:sync_episodes, %{})
      end)

      assert_received :shows_called
      assert_received {:per_series_called, 1}
      assert_received {:per_series_called, 2}
      assert_received :analyzer_dispatched

      assert {:ok, _video} = Media.get_video_by_path("/test/shows/series_1.mkv")
      assert {:ok, _video} = Media.get_video_by_path("/test/shows/series_2.mkv")
    end

    test "writes one item response in bounded chunks" do
      test_pid = self()
      Application.put_env(:reencodarr, :sync_write_batch_size, 2)

      files =
        for id <- 1..5 do
          service_file("/test/bounded/episode_#{id}.mkv", id)
        end

      mock_analyzer_dispatch(test_pid)
      :meck.new(Reencodarr.Services, [:passthrough])

      :meck.expect(Reencodarr.Services, :get_shows, fn ->
        {:ok, %Req.Response{status: 200, body: [%{"id" => 10}]}}
      end)

      :meck.expect(Reencodarr.Services, :get_episode_files, fn 10 ->
        {:ok, %Req.Response{status: 200, body: files}}
      end)

      log =
        capture_info_log(fn ->
          assert {:noreply, %{}} = Sync.handle_cast(:sync_episodes, %{})
        end)

      assert log =~ "Item 10 fetched 5 files, wrote 5 files"

      for file <- files do
        assert {:ok, _video} = Media.get_video_by_path(file["path"])
      end
    end

    test "processes each completed item response without a combined all-files write" do
      test_pid = self()
      Application.put_env(:reencodarr, :sync_write_batch_size, 10)

      mock_analyzer_dispatch(test_pid)
      :meck.new(Reencodarr.Services, [:passthrough])

      :meck.expect(Reencodarr.Services, :get_shows, fn ->
        {:ok, %Req.Response{status: 200, body: [%{"id" => 1}, %{"id" => 2}]}}
      end)

      :meck.expect(Reencodarr.Services, :get_episode_files, fn
        1 ->
          {:ok,
           %Req.Response{
             status: 200,
             body: [
               service_file("/test/per_item/episode_1a.mkv", 101),
               service_file("/test/per_item/episode_1b.mkv", 102)
             ]
           }}

        2 ->
          {:ok,
           %Req.Response{
             status: 200,
             body: [service_file("/test/per_item/episode_2a.mkv", 201)]
           }}
      end)

      log =
        capture_info_log(fn ->
          assert {:noreply, %{}} = Sync.handle_cast(:sync_episodes, %{})
        end)

      assert log =~ "Item 1 fetched 2 files, wrote 2 files"
      assert log =~ "Item 2 fetched 1 files, wrote 1 files"
      assert log =~ "saw 3 files, wrote 3 files"

      assert {:ok, _video} = Media.get_video_by_path("/test/per_item/episode_1a.mkv")
      assert {:ok, _video} = Media.get_video_by_path("/test/per_item/episode_2a.mkv")
    end

    test "logs a failed item fetch and continues with the remaining items" do
      test_pid = self()

      mock_analyzer_dispatch(test_pid)
      :meck.new(Reencodarr.Services, [:passthrough])

      :meck.expect(Reencodarr.Services, :get_shows, fn ->
        {:ok, %Req.Response{status: 200, body: [%{"id" => 1}, %{"id" => 2}]}}
      end)

      :meck.expect(Reencodarr.Services, :get_episode_files, fn
        1 ->
          {:error, :timeout}

        2 ->
          {:ok,
           %Req.Response{
             status: 200,
             body: [service_file("/test/continues/episode_2.mkv", 2)]
           }}
      end)

      log =
        capture_info_log(fn ->
          assert {:noreply, %{}} = Sync.handle_cast(:sync_episodes, %{})
        end)

      assert log =~ "Failed to fetch files for item 1"
      assert log =~ "Item 2 fetched 1 files, wrote 1 files"
      assert {:ok, _video} = Media.get_video_by_path("/test/continues/episode_2.mkv")
    end

    test "empty item file list does not write and does not fail" do
      test_pid = self()

      mock_analyzer_dispatch(test_pid)
      :meck.new(Reencodarr.Services, [:passthrough])

      :meck.expect(Reencodarr.Services, :get_shows, fn ->
        {:ok, %Req.Response{status: 200, body: [%{"id" => 1}]}}
      end)

      :meck.expect(Reencodarr.Services, :get_episode_files, fn 1 ->
        {:ok, %Req.Response{status: 200, body: []}}
      end)

      log =
        capture_info_log(fn ->
          assert {:noreply, %{}} = Sync.handle_cast(:sync_episodes, %{})
        end)

      assert log =~ "Item 1 fetched 0 files, wrote 0 files"
      refute log =~ "Processing 0 changed videos"
      assert Media.count_videos() == 0
      assert_received :analyzer_dispatched
    end
  end

  describe "sync_movies orchestration" do
    test "fetches movies, fetches files per movie, and creates videos" do
      test_pid = self()

      refute function_exported?(Reencodarr.Services, :get_all_movie_files, 0)

      mock_analyzer_dispatch(test_pid)
      :meck.new(Reencodarr.Services, [:passthrough])

      :meck.expect(Reencodarr.Services, :get_movies, fn ->
        send(test_pid, :movies_called)
        {:ok, %Req.Response{status: 200, body: [%{"id" => 3}, %{"id" => 4}]}}
      end)

      :meck.expect(Reencodarr.Services, :get_movie_files, fn movie_id ->
        send(test_pid, {:per_movie_called, movie_id})

        {:ok,
         %Req.Response{
           status: 200,
           body: [service_file("/test/movies/movie_#{movie_id}.mkv", movie_id)]
         }}
      end)

      capture_log(fn ->
        assert {:noreply, %{}} = Sync.handle_cast(:sync_movies, %{})
      end)

      assert_received :movies_called
      assert_received {:per_movie_called, 3}
      assert_received {:per_movie_called, 4}
      assert_received :analyzer_dispatched

      assert {:ok, _video} = Media.get_video_by_path("/test/movies/movie_3.mkv")
      assert {:ok, _video} = Media.get_video_by_path("/test/movies/movie_4.mkv")
    end

    test "analyzer dispatch runs once after sync completion" do
      test_pid = self()

      mock_analyzer_dispatch(test_pid)
      :meck.new(Reencodarr.Services, [:passthrough])

      :meck.expect(Reencodarr.Services, :get_movies, fn ->
        {:ok, %Req.Response{status: 200, body: [%{"id" => 3}]}}
      end)

      :meck.expect(Reencodarr.Services, :get_movie_files, fn 3 ->
        {:ok,
         %Req.Response{
           status: 200,
           body: [service_file("/test/analyzer/movie_3.mkv", 3)]
         }}
      end)

      capture_log(fn ->
        assert {:noreply, %{}} = Sync.handle_cast(:sync_movies, %{})
      end)

      assert_received :analyzer_dispatched
      assert :meck.num_calls(Reencodarr.Analyzer.Broadway, :dispatch_available, []) == 1
    end
  end

  defp mock_analyzer_dispatch(test_pid) do
    :meck.new(Reencodarr.Analyzer.Broadway, [:passthrough])

    :meck.expect(Reencodarr.Analyzer.Broadway, :dispatch_available, fn ->
      send(test_pid, :analyzer_dispatched)
      :ok
    end)
  end

  defp capture_info_log(fun) do
    previous_level = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log(fun)
    after
      Logger.configure(level: previous_level)
    end
  end

  defp restore_env(old_env) do
    Enum.each(old_env, fn
      {key, :unset} -> Application.delete_env(:reencodarr, key)
      {key, value} -> Application.put_env(:reencodarr, key, value)
    end)
  end

  defp service_file(path, id) do
    %{
      "path" => path,
      "size" => 1_000_000_000 + id,
      "id" => id,
      "overallBitrate" => 5_000_000,
      "dateAdded" => "2026-01-01T00:00:00Z"
    }
  end
end
