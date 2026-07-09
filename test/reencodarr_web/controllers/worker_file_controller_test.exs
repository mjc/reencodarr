defmodule ReencodarrWeb.WorkerFileControllerTest do
  use ReencodarrWeb.ConnCase, async: false

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

  defp restore_env(key, nil), do: Application.delete_env(:reencodarr, key)
  defp restore_env(key, value), do: Application.put_env(:reencodarr, key, value)
end
