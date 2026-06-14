defmodule ReencodarrWeb.ConnCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint ReencodarrWeb.Endpoint

      use ReencodarrWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import ReencodarrWeb.ConnCase

      # Make fixtures available via alias
      alias Reencodarr.Fixtures
    end
  end

  setup tags do
    Reencodarr.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
