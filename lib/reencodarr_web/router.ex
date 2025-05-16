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

  scope "/", ReencodarrWeb do
    pipe_through :browser

    live "/", DashboardLive, :index

    live "/videos", VideoLive.Index, :index
    live "/videos/new", VideoLive.Index, :new
    live "/videos/:id/edit", VideoLive.Index, :edit

    live "/videos/:id", VideoLive.Show, :show
    live "/videos/:id/show/edit", VideoLive.Show, :edit

    live "/libraries", LibraryLive.Index, :index
    live "/libraries/new", LibraryLive.Index, :new
    live "/libraries/:id/edit", LibraryLive.Index, :edit

    live "/libraries/:id", LibraryLive.Show, :show
    live "/libraries/:id/show/edit", LibraryLive.Show, :edit

    live "/vmafs", VmafLive.Index, :index
    live "/vmafs/new", VmafLive.Index, :new
    live "/vmafs/:id/edit", VmafLive.Index, :edit

    live "/vmafs/:id", VmafLive.Show, :show
    live "/vmafs/:id/show/edit", VmafLive.Show, :edit

    live "/configs", ConfigLive.Index, :index
    live "/configs/new", ConfigLive.Index, :new
    live "/configs/:id/edit", ConfigLive.Index, :edit

    live "/configs/:id", ConfigLive.Show, :show
    live "/configs/:id/show/edit", ConfigLive.Show, :edit
  end

  scope "/api", ReencodarrWeb do
    pipe_through :api

    post "/webhooks/sonarr", WebhookController, :sonarr
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
  end
end
