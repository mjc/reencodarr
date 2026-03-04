defmodule ReencodarrWeb.HealthController do
  @moduledoc """
  Simple health check endpoint for Docker HEALTHCHECK and load balancers.
  """
  use ReencodarrWeb, :controller

  def index(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
