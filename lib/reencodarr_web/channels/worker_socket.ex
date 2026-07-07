defmodule ReencodarrWeb.WorkerSocket do
  @moduledoc """
  Authenticated websocket socket for ab-av1 worker clients.
  """

  use Phoenix.Socket

  alias Reencodarr.AbAv1.WorkerProtocol

  channel WorkerProtocol.crf_search_topic(), ReencodarrWeb.WorkerChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) when is_binary(token) do
    case Application.fetch_env(:reencodarr, :worker_token) do
      {:ok, configured_token} when is_binary(configured_token) ->
        if Plug.Crypto.secure_compare(configured_token, token) do
          {:ok, assign(socket, :worker_id, worker_id())}
        else
          :error
        end

      _ ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(%{assigns: %{worker_id: worker_id}}), do: "worker_socket:#{worker_id}"
  def id(_socket), do: nil

  defp worker_id, do: "worker-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
end
