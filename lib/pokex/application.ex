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
      # Native CGEvent key helper (~1-2ms per key event vs ~60-100ms osascript).
      # Degrades to :disabled/:untrusted states; Rig.Mac falls back to osascript.
      Pokex.Rig.Mac.KeyEvents,
      # Serializes ALL screen captures (see Pokex.Bots.Capture) — a global singleton, started
      # before the bot so every worker's `Capture.grab` reaches it. Concurrent screencaptures
      # balloon on macOS; one-at-a-time keeps each ~0.28s and the sample cadence steady.
      Pokex.Bots.Capture,
      Pokex.Perception,
      Pokex.Bots.BotSupervisor,
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
