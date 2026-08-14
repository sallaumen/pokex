# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :pokex,
  generators: [timestamp_type: :utc_datetime],
  capture_backend: :auto,
  perf_log_interval_ms: 5_000,
  # Origin of the game's wiki — the ONE place the specific server is named.
  # Everything else in the codebase says "PokeTibia", the genre. `mix
  # pokedex.scrape` reads species data from here and the panel links to it, so
  # pointing at another server also means rewriting the parsers in
  # `Pokex.Pokedex.Scraper`: the HTML shape is not portable. Override at runtime
  # with POKEX_WIKI_BASE (see config/runtime.exs).
  wiki_base: "https://wiki.pokexgames.com"

# Configure the endpoint
config :pokex, PokexWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PokexWeb.ErrorHTML, json: PokexWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Pokex.PubSub,
  live_view: [signing_salt: "KUEpnGwL"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :pokex, Pokex.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  pokex: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  pokex: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
