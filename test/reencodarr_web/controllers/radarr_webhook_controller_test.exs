defmodule ReencodarrWeb.RadarrWebhookControllerTest do
  use ReencodarrWeb.ConnCase, async: false
  import ExUnit.CaptureLog

  alias Reencodarr.Media

  @minimal_media_info %{
    "audioCodec" => "Opus",
    "audioChannels" => 6,
    "videoCodec" => "HEVC",
    "videoDynamicRange" => "HDR",
    "videoDynamicRangeType" => "HDR10",
    "audioLanguages" => "eng",
    "subtitles" => "eng",
    "width" => 3840,
    "height" => 2160
  }

  defp radarr_post(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/webhooks/radarr", body)
  end

  describe "Test event" do
    test "returns 204 and does not crash", %{conn: conn} do
      capture_log(fn ->
        conn = radarr_post(conn, %{"eventType" => "Test"})
        assert conn.status == 204
      end)
    end
  end

  describe "Grab event" do
    test "returns 204", %{conn: conn} do
      capture_log(fn ->
        conn =
          radarr_post(conn, %{
            "eventType" => "Grab",
            "release" => %{"releaseTitle" => "The.Movie.2024.mkv"}
          })

        assert conn.status == 204
      end)
    end
  end

  describe "Download event — movieFile" do
    test "returns 204 and creates a video record", %{conn: conn} do
      uid = System.unique_integer([:positive])
      path = "/test/movies/movie_#{uid}/movie.mkv"

      capture_log(fn ->
        conn =
          radarr_post(conn, %{
            "eventType" => "Download",
            "movieFile" => %{
              "id" => uid,
              "path" => path,
              "size" => 15_000_000_000,
              "mediaInfo" => @minimal_media_info
            }
          })

        assert conn.status == 204
      end)

      assert {:ok, video} = Media.get_video_by_path(path)
      assert video.path == path
      assert video.service_type == :radarr
    end
  end

  describe "Download event — movieFiles list" do
    test "returns 204 and upserts all files", %{conn: conn} do
      uid1 = System.unique_integer([:positive])
      uid2 = System.unique_integer([:positive])
      path1 = "/test/movies/film1_#{uid1}.mkv"
      path2 = "/test/movies/film2_#{uid2}.mkv"

      capture_log(fn ->
        conn =
          radarr_post(conn, %{
            "eventType" => "Download",
            "movieFiles" => [
              %{
                "id" => uid1,
                "path" => path1,
                "size" => 10_000_000_000,
                "mediaInfo" => @minimal_media_info
              },
              %{
                "id" => uid2,
                "path" => path2,
                "size" => 8_000_000_000,
                "mediaInfo" => @minimal_media_info
              }
            ]
          })

        assert conn.status == 204
      end)

      assert {:ok, _} = Media.get_video_by_path(path1)
      assert {:ok, _} = Media.get_video_by_path(path2)
    end
  end

  describe "MovieFileDelete event" do
    test "returns 204 and removes video record", %{conn: conn} do
      uid = System.unique_integer([:positive])
      path = "/test/movies/delete_#{uid}.mkv"

      {:ok, _} = Fixtures.video_fixture(%{path: path, service_type: :radarr})

      capture_log(fn ->
        conn =
          radarr_post(conn, %{
            "eventType" => "MovieFileDelete",
            "movieFile" => %{"path" => path, "relativePath" => "movie.mkv", "id" => uid}
          })

        assert conn.status == 204
      end)

      assert {:error, :not_found} = Media.get_video_by_path(path)
    end
  end

  describe "MovieDelete event" do
    test "returns 204 and deletes all videos under folder path", %{conn: conn} do
      uid = System.unique_integer([:positive])
      folder_path = "/test/movies/folder_#{uid}"
      path1 = "#{folder_path}/version1.mkv"
      path2 = "#{folder_path}/version2.mkv"

      {:ok, _} = Fixtures.video_fixture(%{path: path1, service_type: :radarr})
      {:ok, _} = Fixtures.video_fixture(%{path: path2, service_type: :radarr})

      capture_log(fn ->
        conn =
          radarr_post(conn, %{
            "eventType" => "MovieDelete",
            "movie" => %{
              "title" => "Test Movie",
              "id" => uid,
              "folderPath" => folder_path
            }
          })

        assert conn.status == 204
      end)

      assert {:error, :not_found} = Media.get_video_by_path(path1)
      assert {:error, :not_found} = Media.get_video_by_path(path2)
    end

    test "returns 204 when movie has no recorded files", %{conn: conn} do
      capture_log(fn ->
        conn =
          radarr_post(conn, %{
            "eventType" => "MovieDelete",
            "movie" => %{
              "title" => "Nonexistent Movie",
              "id" => 99_999,
              "folderPath" => "/nonexistent/path"
            }
          })

        assert conn.status == 204
      end)
    end
  end

  describe "Rename event" do
    test "updates existing video path on rename", %{conn: conn} do
      uid = System.unique_integer([:positive])
      old_path = "/test/movies/old_movie_#{uid}.mkv"
      new_path = "/test/movies/new_movie_#{uid}.mkv"

      {:ok, _} = Fixtures.video_fixture(%{path: old_path, service_type: :radarr})

      capture_log(fn ->
        conn =
          radarr_post(conn, %{
            "eventType" => "Rename",
            "renamedMovieFiles" => [
              %{
                "previousPath" => old_path,
                "path" => new_path,
                "id" => uid,
                "size" => 10_000_000,
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

  describe "MovieAdd event" do
    test "returns 204 without crashing", %{conn: conn} do
      capture_log(fn ->
        conn =
          radarr_post(conn, %{
            "eventType" => "MovieAdd",
            "movie" => %{"title" => "New Movie", "id" => 7}
          })

        assert conn.status == 204
      end)
    end
  end

  describe "unknown events" do
    test "returns 204 for unrecognised eventType", %{conn: conn} do
      capture_log(fn ->
        conn = radarr_post(conn, %{"eventType" => "WeirdNewEvent"})
        assert conn.status == 204
      end)
    end

    test "returns 204 when no eventType present", %{conn: conn} do
      capture_log(fn ->
        conn = radarr_post(conn, %{"something" => "else"})
        assert conn.status == 204
      end)
    end
  end
end
