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

    # O header é o mesmo em toda página, então o estado dele é montado uma vez
    # aqui, para a sessão inteira — nenhuma LiveView monta o seu próprio.
    live_session :pokex, on_mount: PokexWeb.HeaderState do
      live "/", PanelLive
      live "/diagnostics", DiagnosticsLive
      live "/mini-game", MiniGameLive
      live "/calibration", CalibrationLive
      live "/fishing-lab", FishingLabLive
      live "/world", WorldLive
      live "/cavebot", CavebotLive
      live "/pokedex", PokedexLive
      live "/time", TeamLive
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
