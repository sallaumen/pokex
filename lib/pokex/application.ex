defmodule Pokex.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PokexWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:pokex, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Pokex.PubSub},
      # Start a worker by calling: Pokex.Worker.start_link(arg)
      # {Pokex.Worker, arg},
      Pokex.Settings,
      Pokex.Bots.Perf,
      # The actuation safety floor — owns the gate ETS table. MUST start before anything that
      # can send a key/click so Rig.Mac's gate check always has a table to read.
      Pokex.Bots.InputGate,
      # Native CGEvent key helper (~1-2ms per key event vs ~60-100ms osascript).
      # Degrades to :disabled/:untrusted states; Rig.Mac falls back to osascript.
      Pokex.Rig.Mac.KeyEvents,
      # Serializes the osascript KEY fallback — System Events is one queue; concurrent key
      # scripts pile up and desync keys from the mouse moves they belong with.
      Pokex.Rig.Mac.OsaBus,
      # Serializes ALL screen captures (see Pokex.Bots.Capture) — a global singleton, started
      # before the bot so every worker's `Capture.grab` reaches it. Concurrent screencaptures
      # balloon on macOS; one-at-a-time keeps each ~0.28s and the sample cadence steady.
      Pokex.Bots.Capture,
      Pokex.Perception,
      Pokex.Bots.BotSupervisor,
      # The anti-shiny watchdog (always-on like Guardian; manages its own
      # arena-feed attachment from the shiny_guard_enabled setting).
      Pokex.Bots.ShinyGuard,
      Pokex.Layout.Sentinel,
      Pokex.Bots.StockAlerts,
      # Pauses everything when the game window loses focus (and resumes on refocus). After the
      # BotSupervisor so it can halt/resume those workers.
      Pokex.Bots.Focus,
      # Start to serve requests, typically the last entry
      PokexWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Pokex.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PokexWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
