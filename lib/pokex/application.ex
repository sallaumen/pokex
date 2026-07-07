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
      Pokex.Bots.Supervisor,
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
