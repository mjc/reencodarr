defmodule ReencodarrWeb.Router do
  use ReencodarrWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ReencodarrWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Pipeline for embedded views (like Broadway Dashboard in iframe)
  pipeline :embedded do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ReencodarrWeb.Layouts, :embedded}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :allow_iframe
  end

  scope "/", ReencodarrWeb do
    pipe_through :browser

    live "/", DashboardLive, :index
    live "/dashboard-v2", DashboardV2Live, :index
    live "/broadway", BroadwayLive, :index
    live "/failures", FailuresLive, :index
    live "/rules", RulesLive, :index

    live "/libraries", LibraryLive.Index, :index
    live "/libraries/new", LibraryLive.Index, :new
    live "/libraries/:id/edit", LibraryLive.Index, :edit

    live "/libraries/:id", LibraryLive.Show, :show
    live "/libraries/:id/show/edit", LibraryLive.Show, :edit

    live "/configs", ConfigLive.Index, :index
    live "/configs/new", ConfigLive.Index, :new
    live "/configs/:id/edit", ConfigLive.Index, :edit

    live "/configs/:id", ConfigLive.Show, :show
    live "/configs/:id/show/edit", ConfigLive.Show, :edit
  end

  scope "/api", ReencodarrWeb do
    pipe_through :api

    post "/webhooks/sonarr", SonarrWebhookController, :sonarr
    post "/webhooks/radarr", RadarrWebhookController, :radarr
  end

  # Other scopes may use custom stacks.
  # scope "/api", ReencodarrWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:reencodarr, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard",
        metrics: ReencodarrWeb.Telemetry,
        additional_pages: [
          broadway: BroadwayDashboard
        ]

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end

    # Embedded Broadway Dashboard for iframe integration
    scope "/embed" do
      pipe_through :embedded

      live "/broadway", ReencodarrWeb.BroadwayLive

      live_dashboard "/dashboard",
        metrics: ReencodarrWeb.Telemetry,
        additional_pages: [
          broadway: BroadwayDashboard
        ],
        live_session_name: :embedded_broadway
    end
  end

  # Plug to allow iframe embedding for Broadway Dashboard
  defp allow_iframe(conn, _opts) do
    conn
    |> delete_resp_header("x-frame-options")
    |> put_resp_header(
      "content-security-policy",
      "frame-ancestors 'self'"
    )
  end
end
