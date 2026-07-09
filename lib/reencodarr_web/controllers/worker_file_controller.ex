defmodule ReencodarrWeb.WorkerFileController do
  @moduledoc false

  use ReencodarrWeb, :controller

  alias Reencodarr.AbAv1.WorkerConfig
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
