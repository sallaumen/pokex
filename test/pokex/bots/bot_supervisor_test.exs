defmodule Pokex.Bots.BotSupervisorTest.ParkedWorker do
  @moduledoc """
  A worker doing what the real ones legitimately do: parked INSIDE one long
  message. The catcher blocks for seconds on a capture the broker holds, and
  every Body user blocks in `Body.perform/3`, which waits `:infinity`. While it
  is parked nothing else in its mailbox is read — the fleet's `:halt` included.
  """
  use GenServer

  def start_link(park_ms), do: GenServer.start_link(__MODULE__, park_ms)

  @impl true
  def init(park_ms) do
    send(self(), :park)
    {:ok, park_ms}
  end

  @impl true
  def handle_info(:park, park_ms) do
    Process.sleep(park_ms)
    {:noreply, park_ms}
  end

  @impl true
  def handle_call(:halt, _from, park_ms), do: {:reply, :ok, park_ms}
end

defmodule Pokex.Bots.BotSupervisorTest.EchoWorker do
  @moduledoc "Answers :halt at once and tells the test it was asked."
  use GenServer

  def start_link(test), do: GenServer.start_link(__MODULE__, test)

  @impl true
  def init(test), do: {:ok, test}

  @impl true
  def handle_call(:halt, _from, test) do
    send(test, {:halted, self()})
    {:reply, :ok, test}
  end
end

defmodule Pokex.Bots.BotSupervisorTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.BotSupervisor
  alias Pokex.Bots.BotSupervisorTest.{EchoWorker, ParkedWorker}
  alias Pokex.Bots.Fisher.Sensors
  alias Pokex.Bots.MiniGame.Worker
  alias Pokex.Bots.Session
  alias Pokex.{Calibration, Settings}
  alias Pokex.Perception.WorldState

  @fast %{
    wait_focus_ms: 5,
    wait_after_equip_ms: 5,
    wait_cast_settle_ms: 5,
    wait_assess_ms: 5,
    tick_ms_watching: 20,
    tick_ms_default: 20,
    watch_dead_streak_needed: 1000,
    watch_timeout_ms: 30_000,
    calm_streak_needed: 1,
    glow_streak_needed: 1,
    glow_threshold: 500,
    max_consecutive_failures: 5,
    tile_px: 32,
    humanize_max_ms: 0,
    cast_delay_max_ms: 0,
    hook_delay_min_ms: 0,
    hook_delay_max_ms: 0
  }

  setup %{tmp_dir: tmp} do
    # one shared blackboard: start from an empty world, never from the last test's
    WorldState.clear()

    Application.put_env(:pokex, :home_dir, tmp)

    on_exit(fn ->
      Pokex.TestHome.restore()
      Enum.each(Settings.defaults(), fn {k, v} -> Settings.put(k, v) end)
    end)

    Enum.each(@fast, fn {k, v} -> Settings.put(k, v) end)

    Calibration.save(%Calibration{
      scale: 2.0,
      screen_w: 1000,
      screen_h: 700,
      water_point: {400, 300},
      glow_region: {368, 268, 64, 64},
      battle_region: {700, 100, 260, 200},
      neutral_point: {420, 350}
    })

    {:ok, _} = Pokex.Rig.Fake.start_link()

    # glow never crosses threshold (stays "watching" forever, never idles) and the Battle list
    # has no candidate (combat stays in :hunting, holding) — so both workers report a
    # stable non-idle state right after start_all/0, instead of racing a full cycle to :idle.
    {:ok, _} =
      Sensors.Fake.start_link(%{
        glow: [50],
        battle: [%{enemies: [], red: [0, 0, 0, 0, 0, 0]}],
        hostile: [{410, 320}]
      })

    :ok
  end

  # Every test starts its own BotSupervisor under private names — the real
  # one from Pokex.Application is already running (under the default
  # module-name registrations) for the lifetime of the test suite, so
  # reusing those names here would collide with it.
  defp start_isolated_supervisor(tag) do
    body = :"#{tag}_body"
    guardian = :"#{tag}_guardian"
    fishing = :"#{tag}_fishing"
    combat = :"#{tag}_combat"
    catcher = :"#{tag}_catcher"
    mini_game = :"#{tag}_mini_game"
    player_support = :"#{tag}_player_support"
    cavebot = :"#{tag}_cavebot"
    timers = :"#{tag}_timers"
    engine = :"#{tag}_engine"

    start_supervised!(
      {BotSupervisor,
       name: nil,
       body: body,
       guardian: guardian,
       fishing: fishing,
       combat: combat,
       catcher: catcher,
       mini_game: mini_game,
       player_support: player_support,
       cavebot: cavebot,
       timers: timers,
       engine: engine}
    )

    %{
      fishing: fishing,
      combat: combat,
      catcher: catcher,
      mini_game: mini_game,
      player_support: player_support,
      cavebot: cavebot,
      timers: timers,
      engine: engine
    }
  end

  defp start_isolated_trio(tag) do
    %{fishing: fishing, combat: combat, catcher: catcher} = start_isolated_supervisor(tag)
    {fishing, combat, catcher}
  end

  @tag :tmp_dir
  test "start_all/0 runs the workers, reflected in status/0" do
    {fishing, combat, catcher} = start_isolated_trio(:start_all_test)

    assert :ok = BotSupervisor.start_all(fishing, combat, catcher)

    status = BotSupervisor.status(fishing, combat, catcher)
    assert status.fishing.state != :idle
    assert status.combat.state != :idle
    assert status.catcher.state == :armed
  end

  # The Stop button, the panic corner, the logout and the focus hold all funnel
  # through the same halt. A stop that left the scheduled actions running would
  # keep pressing keys after the one act that means "stop touching the game" —
  # they were wired into start_all and missing from the halt.
  @tag :tmp_dir
  test "stopping the fleet also stops the scheduled actions" do
    servers = start_isolated_supervisor(:timers_stop_test)
    Pokex.SettingsStash.stash!(player_mode: "still")

    assert :ok =
             BotSupervisor.start_all(
               servers.fishing,
               servers.combat,
               servers.catcher,
               servers.mini_game,
               servers.player_support,
               servers.cavebot,
               servers.timers
             )

    assert Pokex.Bots.Timers.Worker.status(servers.timers).running?

    BotSupervisor.stop_all(
      servers.fishing,
      servers.combat,
      servers.catcher,
      servers.mini_game,
      servers.player_support,
      servers.cavebot,
      servers.timers
    )

    refute Pokex.Bots.Timers.Worker.status(servers.timers).running?
  end

  @tag :tmp_dir
  test "stop_all/0 idles all workers and is idempotent on a second call" do
    {fishing, combat, catcher} = start_isolated_trio(:stop_all_test)

    assert :ok = BotSupervisor.start_all(fishing, combat, catcher)
    assert :ok = BotSupervisor.stop_all(fishing, combat, catcher)

    status = BotSupervisor.status(fishing, combat, catcher)
    assert status.fishing.state == :idle
    assert status.combat.state == :idle
    assert status.catcher.state == :idle

    assert :ok = BotSupervisor.stop_all(fishing, combat, catcher)

    status = BotSupervisor.status(fishing, combat, catcher)
    assert status.fishing.state == :idle
    assert status.combat.state == :idle
    assert status.catcher.state == :idle
  end

  @tag :tmp_dir
  test "start_all/0 surfaces a preflight/calibration error instead of starting any worker" do
    File.rm!(Pokex.Home.calibration_file())

    {fishing, combat, catcher} = start_isolated_trio(:error_test)

    Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")

    assert {:error, [msg]} = BotSupervisor.start_all(fishing, combat, catcher)
    assert msg =~ "calibração"

    # A refused start is ANNOUNCED by the owner of the operation, so no caller
    # can swallow it — both did: the command corner threw the return away inside
    # a fire-and-forget Task, and the panel put it in an assign no feed ever saw.
    # One worker refusing halts the whole chain, so the fleet sat stopped with
    # nothing on screen but "ligando o modo still" (Lucas, 2026-08-07).
    assert_receive {:rule_alarm, :command, alarm}, 1_000
    assert alarm =~ "NÃO ligou"
    assert alarm =~ "calibração"

    status = BotSupervisor.status(fishing, combat, catcher)
    assert status.fishing.state == :idle
    assert status.combat.state == :idle
    assert status.catcher.state == :idle
  end

  @tag :tmp_dir
  test "start_all/5 stamps the :calibration fact; stop_all/5 forgets it" do
    alias Pokex.Perception.WorldState

    {fishing, combat, catcher} = start_isolated_trio(:stamp_test)
    mini_game = :stamp_test_mini_game
    player_support = :stamp_test_player_support

    on_exit(fn ->
      WorldState.forget(:calibration)
      WorldState.forget(:session)
    end)

    assert :ok = BotSupervisor.start_all(fishing, combat, catcher, mini_game, player_support)

    now = System.monotonic_time(:millisecond)
    assert {:ok, %{loaded_mtime: loaded}} = WorldState.get(:calibration, 4_000_000_000, now)
    assert loaded == Pokex.Calibration.mtime()

    assert {:ok, %{started_at: started_at}} = WorldState.get(:session, 4_000_000_000, now)
    assert is_integer(started_at)

    assert :ok = BotSupervisor.stop_all(fishing, combat, catcher, mini_game, player_support)
    assert WorldState.get(:calibration, 4_000_000_000, now) == :missing
    assert WorldState.get(:session, 4_000_000_000, now) == :missing
  end

  # The mode is what "Iniciar" means. Walking around, the rod and the mini-game
  # watcher have nothing to do — starting them would cast a line at whatever
  # water he happens to be passing.
  # SettingsStash, not Settings.put: a player_mode left in the GLOBAL test settings file
  # poisons every later run of the suite.
  @tag :tmp_dir
  test "start_all/5 in movimento mode starts combat but not fishing or the mini game" do
    servers = start_isolated_supervisor(:moving_test)
    Pokex.SettingsStash.stash!(player_mode: "moving")

    assert :ok =
             BotSupervisor.start_all(
               servers.fishing,
               servers.combat,
               servers.catcher,
               servers.mini_game,
               servers.player_support,
               servers.cavebot,
               servers.timers
             )

    status = BotSupervisor.status(servers.fishing, servers.combat, servers.catcher)
    assert status.fishing.state == :idle
    assert Worker.status(servers.mini_game).state == :off

    assert status.combat.state != :idle
    assert status.catcher.state != :idle
  end

  # Caçada is the cavebot's mode: it walks the route and drives the Combat
  # itself, so start_all must NOT arm the fight directly — only the cavebot,
  # the catcher (Space loot) and the support come up.
  @tag :tmp_dir
  test "start_all in caçada mode starts the cavebot without fishing or direct combat; stop_all idles it" do
    alias Pokex.Bots.Cavebot

    servers = start_isolated_supervisor(:cacada_test)
    Pokex.SettingsStash.stash!(player_mode: "hunt")

    {:ok, route} = Cavebot.Route.append(Cavebot.Route.new("rota de teste"), {10, 12, 5})
    :ok = Cavebot.Store.add(route)

    assert :ok =
             BotSupervisor.start_all(
               servers.fishing,
               servers.combat,
               servers.catcher,
               servers.mini_game,
               servers.player_support,
               servers.cavebot,
               servers.timers
             )

    status =
      BotSupervisor.status(
        servers.fishing,
        servers.combat,
        servers.catcher,
        servers.mini_game,
        servers.player_support,
        servers.cavebot
      )

    assert status.cavebot.state != :idle
    assert status.cavebot.route == "rota de teste"
    assert status.combat.state == :idle
    assert status.fishing.state == :idle
    assert Worker.status(servers.mini_game).state == :off

    assert :ok =
             BotSupervisor.stop_all(
               servers.fishing,
               servers.combat,
               servers.catcher,
               servers.mini_game,
               servers.player_support,
               servers.cavebot
             )

    status =
      BotSupervisor.status(
        servers.fishing,
        servers.combat,
        servers.catcher,
        servers.mini_game,
        servers.player_support,
        servers.cavebot
      )

    assert status.cavebot.state == :idle
  end

  @tag :tmp_dir
  test "emergency_escape without a calibrated ladder still latches, stops, and broadcasts", %{
    tmp_dir: tmp
  } do
    alias Pokex.Bots.InputGate

    Application.put_env(:pokex, :home_dir, tmp)

    on_exit(fn ->
      Pokex.TestHome.restore()
      InputGate.set_panic_latch(false)
    end)

    Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")

    assert {:error, :not_calibrated} = BotSupervisor.emergency_escape("teste")
    assert InputGate.panic_latched?()
    assert_receive {:escape, "teste", {:error, :not_calibrated}}, 1_000
  end

  # The single most safety-critical invariant of the whole bot: the Guardian's
  # panic corner runs stop_all/5, and that MUST release a Space the mini-game
  # player is holding — a stuck Space keeps acting in the game after the human
  # asked everything to stop.
  @tag :tmp_dir
  test "panic stop_all releases a Space held by the mini-game player", %{tmp_dir: tmp} do
    {fishing, combat, catcher} = start_isolated_trio(:panic_release_test)
    mini_game = :panic_release_test_mini_game
    player_support = :panic_release_test_player_support

    Enum.each(
      %{
        mini_game_tick_ms: 20,
        mini_game_enter_streak: 1,
        mini_game_exit_streak: 1,
        mini_game_min_confidence: 0.6,
        mini_game_min_dark_ratio: 0.34,
        mini_game_play_tick_ms: 20,
        mini_game_min_toggle_ms: 0,
        mini_game_mode: "auto"
      },
      fn {k, v} -> Settings.put(k, v) end
    )

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: 220,
      screen_h: 220,
      water_point: {100, 100},
      glow_region: {0, 0, 20, 20},
      battle_region: {0, 0, 20, 20},
      # a faixa é MARCADA: desde 2026-08-05 o vigia não adivinha região nenhuma
      # (o palpite lia cenário como minigame), então sem marca ele fica cego —
      # e um vigia cego nunca chega a segurar Espaço pra este teste soltar
      mini_game_region: {0, 0, 220, 220},
      neutral_point: {100, 100}
    })

    game = Pokex.PngFixtures.mini_game_scene!(tmp, "hold.png", fish: 40..54, capsule: 100..114)
    Agent.stop(Pokex.Rig.Fake)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, game}]})

    assert :ok = Worker.run(mini_game)
    wait_for(fn -> {:key_down, "space"} in Pokex.Rig.Fake.calls() end)

    assert :ok = BotSupervisor.stop_all(fishing, combat, catcher, mini_game, player_support)

    assert {:key_up, "space"} in Pokex.Rig.Fake.calls()
    assert Worker.status(mini_game).state == :off
  end

  # A fleet stop is the one thing that must work when everything else is wedged.
  # It was built out of plain GenServer.calls, so the first worker that did not
  # answer within the default 5s EXITED the caller: on 2026-08-11 that caller
  # was the Guardian's panic corner, it died on the catcher, and the mini game,
  # the player support and both `forget`s that come after it never ran.
  @tag :tmp_dir
  @tag :capture_log
  test "a worker that will not answer neither aborts the fleet stop nor kills the caller" do
    # longer than any call timeout: it is killed outright on teardown, since it
    # traps nothing — exactly like a worker still inside a wedged capture
    parked = start_supervised!({ParkedWorker, 60_000}, id: :parked)
    cavebot = start_supervised!({EchoWorker, self()}, id: :cavebot)
    fishing = start_supervised!({EchoWorker, self()}, id: :fishing)
    combat = start_supervised!({EchoWorker, self()}, id: :combat)
    mini_game = start_supervised!({EchoWorker, self()}, id: :mini_game)
    player_support = start_supervised!({EchoWorker, self()}, id: :player_support)

    # the catcher slot is the parked one — the two workers below it in
    # halt_fleet's order are what the crash never reached
    assert :ok =
             BotSupervisor.stop_all(
               fishing,
               combat,
               parked,
               mini_game,
               player_support,
               cavebot
             )

    assert_receive {:halted, ^cavebot}
    assert_receive {:halted, ^fishing}
    assert_receive {:halted, ^combat}
    assert_receive {:halted, ^mini_game}
    assert_receive {:halted, ^player_support}
  end

  # Header, panel, and Focus all consult active?/1 — the single "is it running" gauge.
  @tag :tmp_dir
  test "active?/1 is the single activity gauge — stopped-with-reason is not active" do
    for idle <- [:idle, :off, :busy, :error, :manual] do
      refute BotSupervisor.active?(idle)
      refute BotSupervisor.active?(%{state: idle})
    end

    for rodando <- [:fishing, :hunting, :walking, :fighting, :watching] do
      assert BotSupervisor.active?(rodando)
    end

    for cavebot_stop <- [:blocked, :stuck, :fight_stalled] do
      refute BotSupervisor.active?(cavebot_stop)
      refute BotSupervisor.active?(%{state: cavebot_stop})
    end

    assert BotSupervisor.any_active?([%{state: :idle}, %{state: :walking}])
    refute BotSupervisor.any_active?([%{state: :idle}, %{state: :blocked}])
  end

  # Every start/stop/panic/logout order funnels through stop_all/0 or start_all/0; the
  # generation bump is what kills a pending Focus resume when an order lands mid-blur.
  # In test env start_all/0 boots the real global fleet against the fake Rig — it must be
  # stopped right after, or the global worker keeps ticking against a dead sensor.
  @tag :tmp_dir
  test "stop_all/0 and start_all/0 bump the generation — even a start that fails" do
    antes = Session.generation()

    :ok = BotSupervisor.stop_all()
    after_stop = Session.generation()
    assert after_stop > antes

    on_exit(fn -> BotSupervisor.stop_all() end)
    _result = BotSupervisor.start_all()
    assert Session.generation() > after_stop

    :ok = BotSupervisor.stop_all()
  end

  @tag :tmp_dir
  test "hold_for_focus returns the generation of its own pause" do
    generation = BotSupervisor.hold_for_focus()

    assert is_integer(generation)
    assert generation == Session.generation()
  end

  defp wait_for(fun, tries \\ 100) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        ExUnit.Assertions.flunk(
          "condition never became true; calls: #{inspect(Pokex.Rig.Fake.calls())}"
        )

      true ->
        Process.sleep(10)
        wait_for(fun, tries - 1)
    end
  end
end
