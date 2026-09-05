defmodule PokexWeb.Router do
  use PokexWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PokexWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", PokexWeb do
    pipe_through :browser

    get "/captures/:name", CapturesController, :show
    # a wildcard so a mini-game evidence BUNDLE (a directory) is browsable too
    get "/exports/*path", ExportsController, :show

    # The header is the same on every page, so its state is mounted once
    # here, for the whole session — no LiveView mounts its own.
    live_session :pokex, on_mount: PokexWeb.HeaderState do
      live "/", PanelLive
      # SAME LiveView: the ⚙️ is an overlay ON TOP of the live dashboard, not
      # another page. The route exists to give its own URL, F5 and back.
      live "/config", ConfigLive
      # the composite editors (balls, presets, shiny) stay in the panel overlay: forms
      # with their own state do not fit the /config schema
      live "/config/editores", PanelLive, :config
      live "/diagnostics", DiagnosticsLive
      live "/mini-game", MiniGameLive
      live "/calibration", CalibrationLive
      live "/fishing-lab", FishingLabLive
      live "/world", WorldLive
      live "/cavebot", CavebotLive
      live "/sim", SimLive
      live "/pokedex", PokedexLive
      live "/time", TeamLive
      live "/timers", TimersLive
      live "/pokedex/:name", PokedexDetailLive
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", PokexWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:pokex, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: PokexWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
