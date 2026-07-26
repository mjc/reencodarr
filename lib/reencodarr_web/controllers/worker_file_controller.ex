defmodule ReencodarrWeb.WorkerFileController do
  @moduledoc false

  use ReencodarrWeb, :controller

  alias Reencodarr.AbAv1.{Encode, WorkerConfig}
  alias Reencodarr.Media

  def show(conn, %{"id" => id}) do
    with :ok <- authorize(conn),
         {video_id, ""} <- Integer.parse(id),
         %Media.Video{path: path} <- Media.get_video(video_id),
         true <- File.regular?(path) do
      conn
      |> put_resp_content_type("application/octet-stream")
      |> send_file(200, path)
    else
      {:error, :unauthorized} -> send_resp(conn, 401, "unauthorized")
      _ -> send_resp(conn, 404, "not found")
    end
  end

  def upload(conn, %{"id" => id, "attempt_id" => attempt_id}) do
    with :ok <- authorize(conn),
         {video_id, ""} <- Integer.parse(id),
         %Media.Video{state: :encoding, worker_attempt_id: ^attempt_id} = video <-
           Media.get_video(video_id),
         :ok <- receive_output(conn, video, attempt_id) do
      send_resp(conn, 204, "")
    else
      {:error, :unauthorized} -> send_resp(conn, 401, "unauthorized")
      {:error, :stale_worker_attempt} -> send_resp(conn, 409, "stale worker attempt")
      %Media.Video{} -> send_resp(conn, 409, "stale worker attempt")
      _ -> send_resp(conn, 404, "not found")
    end
  end

  defp receive_output(conn, video, attempt_id) do
    output_path = Encode.output_file(video)
    partial_path = output_path <> "." <> upload_suffix(attempt_id) <> ".upload"
    File.mkdir_p!(Path.dirname(output_path))
    File.rm(partial_path)

    result =
      with {:ok, file} <- File.open(partial_path, [:write, :binary, :exclusive]),
           :ok <- copy_and_close(conn, file) do
        Media.commit_worker_output_upload(video.id, attempt_id, partial_path, output_path)
      end

    if result != :ok, do: File.rm(partial_path)
    result
  end

  defp upload_suffix(attempt_id) do
    :sha256
    |> :crypto.hash(attempt_id)
    |> Base.url_encode64(padding: false)
  end

  defp copy_and_close(conn, file) do
    copy_body(conn, file)
  after
    File.close(file)
  end

  defp copy_body(conn, file) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, _conn} -> IO.binwrite(file, body)
      {:more, body, conn} -> with :ok <- IO.binwrite(file, body), do: copy_body(conn, file)
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize(conn) do
    with ["Bearer " <> provided] <- get_req_header(conn, "authorization"),
         token when is_binary(token) <- WorkerConfig.transfer_token(),
         true <- byte_size(provided) == byte_size(token),
         true <- Plug.Crypto.secure_compare(provided, token) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end
end
