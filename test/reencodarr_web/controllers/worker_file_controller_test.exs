defmodule ReencodarrWeb.WorkerFileControllerTest do
  use ReencodarrWeb.ConnCase, async: false

  alias Reencodarr.AbAv1.Encode

  test "requires worker bearer token", %{conn: conn} do
    previous = Application.get_env(:reencodarr, :worker_token)
    previous_transfer = Application.get_env(:reencodarr, :worker_transfer_token)
    Application.put_env(:reencodarr, :worker_token, "test-token")
    Application.delete_env(:reencodarr, :worker_transfer_token)

    on_exit(fn ->
      restore_env(:worker_token, previous)
      restore_env(:worker_transfer_token, previous_transfer)
    end)

    conn = get(conn, ~p"/workers/files/123")

    assert conn.status == 401
  end

  test "sends the video file to authorized workers", %{conn: conn} do
    previous = Application.get_env(:reencodarr, :worker_token)
    previous_transfer = Application.get_env(:reencodarr, :worker_transfer_token)
    Application.put_env(:reencodarr, :worker_transfer_token, "transfer-token")

    on_exit(fn ->
      restore_env(:worker_token, previous)
      restore_env(:worker_transfer_token, previous_transfer)
    end)

    path = Path.join(System.tmp_dir!(), "reencodarr-worker-file-#{System.unique_integer()}.mkv")
    File.write!(path, "video bytes")
    on_exit(fn -> File.rm(path) end)

    {:ok, video} = Fixtures.video_fixture(%{path: path, size: byte_size("video bytes")})

    conn =
      conn
      |> put_req_header("authorization", "Bearer transfer-token")
      |> get(~p"/workers/files/#{video.id}")

    assert conn.status == 200
    assert conn.resp_body == "video bytes"
    assert [content_type] = get_resp_header(conn, "content-type")
    assert String.starts_with?(content_type, "application/octet-stream")
  end

  test "stores an authorized encode output for completion", %{conn: conn} do
    previous_token = Application.get_env(:reencodarr, :worker_transfer_token)
    previous_temp_dir = Application.get_env(:reencodarr, :temp_dir)
    temp_dir = Path.join(System.tmp_dir!(), "reencodarr-worker-output-#{System.unique_integer()}")
    Application.put_env(:reencodarr, :worker_transfer_token, "transfer-token")
    Application.put_env(:reencodarr, :temp_dir, temp_dir)

    on_exit(fn ->
      restore_env(:worker_transfer_token, previous_token)
      restore_env(:temp_dir, previous_temp_dir)
      File.rm_rf(temp_dir)
    end)

    {:ok, video} = Fixtures.video_fixture(%{path: "/videos/movie.mkv", size: 1_000})

    conn =
      conn
      |> put_req_header("authorization", "Bearer transfer-token")
      |> put_req_header("content-type", "application/octet-stream")
      |> put(~p"/workers/files/#{video.id}/output", "encoded bytes")

    assert conn.status == 204
    assert File.read!(Encode.output_file(video)) == "encoded bytes"
  end

  defp restore_env(key, nil), do: Application.delete_env(:reencodarr, key)
  defp restore_env(key, value), do: Application.put_env(:reencodarr, key, value)
end
