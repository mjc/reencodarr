defmodule ReencodarrWeb.ChannelCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint ReencodarrWeb.Endpoint

      import Phoenix.ChannelTest

      import ReencodarrWeb.ChannelCase
    end
  end

  setup tags do
    Reencodarr.DataCase.setup_sandbox(tags)
    :ok
  end
end
