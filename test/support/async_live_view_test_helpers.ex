defmodule ReencodarrWeb.AsyncLiveViewTestHelpers do
  @moduledoc false
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest
  @endpoint ReencodarrWeb.Endpoint

  def live_loaded(conn, path) do
    case live(conn, path) do
      {:ok, view, _html} -> {:ok, view, render_async(view)}
      result -> result
    end
  end
end
