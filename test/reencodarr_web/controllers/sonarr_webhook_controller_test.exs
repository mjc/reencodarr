defmodule ReencodarrWeb.SonarrWebhookControllerTest do
  use ReencodarrWeb.ConnCase, async: false
  import ExUnit.CaptureLog

  alias Phoenix.PubSub
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Media

  @minimal_media_info %{
    "audioCodec" => "AAC",
    "audioChannels" => 2,
    "videoCodec" => "H264",
    "videoDynamicRange" => nil,
    "videoDynamicRangeType" => nil,
    "audioLanguages" => "eng",
    "subtitles" => "eng",
    "width" => 1920,
    "height" => 1080
  }

  defp sonarr_post(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/webhooks/sonarr", body)
  end

  describe "Test event" do
    test "returns 204 and does not crash", %{conn: conn} do
      capture_log(fn ->
        conn = sonarr_post(conn, %{"eventType" => "Test"})
        assert conn.status == 204
      end)
    end
  end

  describe "Grab event" do
    test "returns 204 without touching DB", %{conn: conn} do
      capture_log(fn ->
        conn =
          sonarr_post(conn, %{
            "eventType" => "Grab",
            "release" => %{"releaseTitle" => "Show.S01E01.mkv"}
          })

        assert conn.status == 204
      end)
    end
  end

  describe "Download event — episodeFile" do
    test "returns 204 and creates a video record", %{conn: conn} do
      unique = System.unique_integer([:positive])
      path = "/test/shows/show_#{unique}/episode.mkv"

      capture_log(fn ->
        conn =
          sonarr_post(conn, %{
            "eventType" => "Download",
            "episodeFile" => %{
              "id" => unique,
              "path" => path,
              "size" => 2_000_000_000,
              "sceneName" => "Show.S01E01.HDTV",
              "mediaInfo" => @minimal_media_info
            }
          })

        assert conn.status == 204
      end)

      assert {:ok, video} = Media.get_video_by_path(path)
      assert video.path == path
      assert video.service_type == :sonarr
    end

    test "marks a waiting bad-file issue replaced_clean when Sonarr reports the replacement", %{
      conn: conn
    } do
      unique = System.unique_integer([:positive])
      path = "/test/shows/replacement_#{unique}/episode.mkv"

      {:ok, video} =
        Fixtures.video_fixture(%{
          path: path,
          size: 1_000_000_000,
          service_type: :sonarr,
          service_id: Integer.to_string(unique)
        })

      {:ok, issue} =
        Media.create_bad_file_issue(video, %{
          origin: :manual,
          issue_kind: :manual,
          classification: :manual_bad,
          manual_reason: "bad encode"
        })

      {:ok, _waiting_issue} = Media.update_bad_file_issue_status(issue, :waiting_for_replacement)

      capture_log(fn ->
        conn =
          sonarr_post(conn, %{
            "eventType" => "Download",
            "episodeFile" => %{
              "id" => unique,
              "path" => path,
              "size" => 2_000_000_000,
              "sceneName" => "Show.S01E01.REPACK",
              "mediaInfo" => @minimal_media_info
            }
          })

        assert conn.status == 204
      end)

      assert Media.get_bad_file_issue!(issue.id).status == :replaced_clean
    end

    test "broadcasts an existing dashboard sync event when Sonarr reports the replacement", %{
      conn: conn
    } do
      PubSub.subscribe(Reencodarr.PubSub, Events.channel())

      unique = System.unique_integer([:positive])
      path = "/test/shows/broadcast_#{unique}/episode.mkv"

      capture_log(fn ->
        conn =
          sonarr_post(conn, %{
            "eventType" => "Download",
            "episodeFile" => %{
              "id" => unique,
              "path" => path,
              "size" => 2_000_000_000,
              "sceneName" => "Show.S01E01.REPACK",
              "mediaInfo" => @minimal_media_info
            }
          })

        assert conn.status == 204
      end)

      assert_receive {:sync_completed, %{service_type: :sonarr, source: :webhook, path: ^path}}
    end

    test "returns 204 for episodeFile with invalid/missing size", %{conn: conn} do
      capture_log(fn ->
        conn =
          sonarr_post(conn, %{
            "eventType" => "Download",
            "episodeFile" => %{
              "id" => "999",
              "path" => "/some/path.mkv",
              "size" => nil,
              "mediaInfo" => @minimal_media_info
            }
          })

        # Controller still returns 204 (errors logged, not raised)
        assert conn.status == 204
      end)
    end
  end

  describe "Download event — episodeFiles list" do
    test "returns 204 and upserts each file", %{conn: conn} do
      uid1 = System.unique_integer([:positive])
      uid2 = System.unique_integer([:positive])
      path1 = "/test/batch/ep_#{uid1}.mkv"
      path2 = "/test/batch/ep_#{uid2}.mkv"

      capture_log(fn ->
        conn =
          sonarr_post(conn, %{
            "eventType" => "Download",
            "episodeFiles" => [
              %{
                "id" => uid1,
                "path" => path1,
                "size" => 1_000_000_000,
                "mediaInfo" => @minimal_media_info
              },
              %{
                "id" => uid2,
                "path" => path2,
                "size" => 1_500_000_000,
                "mediaInfo" => @minimal_media_info
              }
            ]
          })

        assert conn.status == 204
      end)

      assert {:ok, _} = Media.get_video_by_path(path1)
      assert {:ok, _} = Media.get_video_by_path(path2)
    end

    test "returns 204 and upserts files when mediaInfo is missing", %{conn: conn} do
      uid = System.unique_integer([:positive])
      path = "/test/batch/no_media_info_#{uid}.mkv"

      log =
        capture_log(fn ->
          conn =
            sonarr_post(conn, %{
              "eventType" => "Download",
              "episodeFiles" => [
                %{
                  "id" => uid,
                  "path" => path,
                  "size" => 1_250_000_000,
                  "sceneName" => "Show.S01E08.1080p.BluRay.Remux",
                  "quality" => "Bluray-1080p Remux"
                }
              ]
            })

          assert conn.status == 204
        end)

      refute String.contains?(log, "FunctionClauseError")
    end
  end

  describe "EpisodeFileDelete event" do
    test "returns 204 and removes the video record", %{conn: conn} do
      uid = System.unique_integer([:positive])
      path = "/test/delete/ep_#{uid}.mkv"

      # Pre-create through a fixture
      {:ok, _video} = Fixtures.video_fixture(%{path: path})

      capture_log(fn ->
        conn =
          sonarr_post(conn, %{
            "eventType" => "EpisodeFileDelete",
            "episodeFile" => %{"path" => path, "id" => uid}
          })

        assert conn.status == 204
      end)

      assert {:error, :not_found} = Media.get_video_by_path(path)
    end
  end

  describe "SeriesDelete event" do
    test "returns 204 and removes all videos under the series path", %{conn: conn} do
      uid = System.unique_integer([:positive])
      base_path = "/test/series/series_#{uid}"
      path1 = "#{base_path}/S01/ep1.mkv"
      path2 = "#{base_path}/S01/ep2.mkv"

      {:ok, _} = Fixtures.video_fixture(%{path: path1})
      {:ok, _} = Fixtures.video_fixture(%{path: path2})

      capture_log(fn ->
        conn =
          sonarr_post(conn, %{
            "eventType" => "SeriesDelete",
            "series" => %{
              "title" => "Test Series",
              "id" => uid,
              "path" => base_path
            }
          })

        assert conn.status == 204
      end)

      assert {:error, :not_found} = Media.get_video_by_path(path1)
      assert {:error, :not_found} = Media.get_video_by_path(path2)
    end

    test "returns 204 when series has no recorded videos", %{conn: conn} do
      capture_log(fn ->
        conn =
          sonarr_post(conn, %{
            "eventType" => "SeriesDelete",
            "series" => %{
              "title" => "Nonexistent Show",
              "id" => 99_999,
              "path" => "/nonexistent/path"
            }
          })

        assert conn.status == 204
      end)
    end
  end

  describe "SeriesAdd event" do
    test "returns 204 without crashing", %{conn: conn} do
      capture_log(fn ->
        conn =
          sonarr_post(conn, %{
            "eventType" => "SeriesAdd",
            "series" => %{"title" => "New Show", "id" => 42}
          })

        assert conn.status == 204
      end)
    end
  end

  describe "Rename event" do
    test "updates existing video path on rename", %{conn: conn} do
      uid = System.unique_integer([:positive])
      old_path = "/test/rename/old_ep_#{uid}.mkv"
      new_path = "/test/rename/new_ep_#{uid}.mkv"

      {:ok, _} = Fixtures.video_fixture(%{path: old_path})

      capture_log(fn ->
        conn =
          sonarr_post(conn, %{
            "eventType" => "Rename",
            "renamedEpisodeFiles" => [
              %{
                "previousPath" => old_path,
                "path" => new_path,
                "id" => uid,
                "size" => 1_000_000,
                "mediaInfo" => @minimal_media_info
              }
            ]
          })

        assert conn.status == 204
      end)

      assert {:error, :not_found} = Media.get_video_by_path(old_path)
      assert {:ok, _} = Media.get_video_by_path(new_path)
    end
  end

  describe "unknown event" do
    test "returns 204 for unrecognised eventType", %{conn: conn} do
      capture_log(fn ->
        conn = sonarr_post(conn, %{"eventType" => "SomeNewEvent"})
        assert conn.status == 204
      end)
    end

    test "returns 204 when eventType is missing", %{conn: conn} do
      capture_log(fn ->
        conn = sonarr_post(conn, %{"something" => "else"})
        assert conn.status == 204
      end)
    end
  end
end
