defmodule Pokex.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PokexWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:pokex, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Pokex.PubSub},
      Pokex.Settings,
      # One queue for the read-modify-write of the state files under the home:
      # two of those at once lose one of the two writes whole (see Pokex.StateFile).
      Pokex.StateFile,
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
      # Session generation: order counter that invalidates stale resumes. Must start
      # before BotSupervisor since every order goes through it.
      Pokex.Bots.Session,
      Pokex.Bots.BotSupervisor,
      # AFTER the fleet on purpose: recovering from a fence that died armed halts
      # the workers by name, so they have to exist. They come up idle, so there is
      # no window to race — nothing walks until start_all/0, which this guards.
      Pokex.Sim.Fence,
      # Idle until a screen loads a route into it. Registered under its own name
      # because that name is the wiring: Pokex.Rig.Sim reports every key to it.
      Pokex.Sim.Runner,
      # The anti-shiny watchdog (always-on like Guardian; manages its own
      # arena-feed attachment from the shiny_guard_enabled setting).
      Pokex.Bots.ShinyGuard,
      # Ends the session (idle/goal rules or the manual button). After BotSupervisor
      # because it halts the fleet.
      Pokex.Bots.Logout,
      Pokex.Layout.Sentinel,
      Pokex.Bots.StockAlerts,
      # History that survives page reloads: subscribes to worker topics, keeps the
      # ring buffer outside LiveView. Passive — never captures or actuates.
      Pokex.Journal,
      # The same nights, typed: what the journal keeps as prose for him, this
      # keeps as numbers for the engine to be calibrated against later.
      Pokex.Engine.Events,
      # Pauses everything when the game window loses focus (and resumes on refocus). After the
      # BotSupervisor so it can halt/resume those workers.
      Pokex.Bots.Focus,
      # Notices OTHER Pokex VMs running on this Mac and says so on every page. Detection only:
      # it holds no authority over anything above it, so its position in this list is free and
      # a failure of its own can never stop the bot.
      Pokex.Machine.Presence,
      PokexWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Pokex.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      # After Settings is up: an `:active_character` pointing at a folder that
      # no longer exists makes the team silently disappear from the screen.
      Pokex.Characters.heal_active()
      {:ok, pid}
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    PokexWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
