defmodule Pokex.Bots.BotSupervisorTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.BotSupervisor
  alias Pokex.Bots.Fisher.Sensors
  alias Pokex.{Calibration, Settings}

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
    Application.put_env(:pokex, :home_dir, tmp)

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
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
      arena_region: {200, 100, 400, 400},
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
       cavebot: cavebot}
    )

    %{
      fishing: fishing,
      combat: combat,
      catcher: catcher,
      mini_game: mini_game,
      player_support: player_support,
      cavebot: cavebot
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
    # catcher is armed by start_all in the default "parado" mode, waiting for a corpse
    assert status.catcher.state == :armed
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

    # A second stop_all/0 while already idle must be a safe no-op — this is
    # exactly what the Guardian does on every poll tick while the cursor
    # sits in the panic corner.
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

    assert {:error, [msg]} = BotSupervisor.start_all(fishing, combat, catcher)
    assert msg =~ "calibração"

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

    # the hunt session starts with the workers (panel duration/rates read this)
    assert {:ok, %{started_at: started_at}} = WorldState.get(:session, 4_000_000_000, now)
    assert is_integer(started_at)

    assert :ok = BotSupervisor.stop_all(fishing, combat, catcher, mini_game, player_support)
    assert WorldState.get(:calibration, 4_000_000_000, now) == :missing
    assert WorldState.get(:session, 4_000_000_000, now) == :missing
  end

  # The mode is what "Iniciar" means. Walking around, the rod and the mini-game
  # watcher have nothing to do — starting them would cast a line at whatever
  # water he happens to be passing.
  @tag :tmp_dir
  test "start_all/5 em movimento NÃO liga a pesca nem o mini game, e ainda liga a luta" do
    servers = start_isolated_supervisor(:movimento_test)
    # per-key restore: the blanket "put every default back" in setup writes to
    # the GLOBAL test settings file, and a mode left behind there poisons every
    # later run of the suite — this one cost an afternoon to trace.
    Pokex.SettingsStash.stash!(player_mode: "movimento")

    assert :ok =
             BotSupervisor.start_all(
               servers.fishing,
               servers.combat,
               servers.catcher,
               servers.mini_game,
               servers.player_support
             )

    status = BotSupervisor.status(servers.fishing, servers.combat, servers.catcher)
    assert status.fishing.state == :idle
    assert Pokex.Bots.MiniGame.Worker.status(servers.mini_game).state == :off

    # what movimento IS: the bot fights, and the catcher stays up for the Space loot
    assert status.combat.state != :idle
    assert status.catcher.state != :idle
  end

  # Caçada is the cavebot's mode: it walks the route and drives the Combat
  # itself, so start_all must NOT arm the fight directly — only the cavebot,
  # the catcher (Space loot) and the support come up.
  @tag :tmp_dir
  test "start_all em caçada sobe o cavebot, sem pesca nem combat direto; stop_all o derruba" do
    alias Pokex.Bots.Cavebot

    servers = start_isolated_supervisor(:cacada_test)
    Pokex.SettingsStash.stash!(player_mode: "caçada")

    # a valid, enabled route — without one the cavebot's run fails preflight
    {:ok, route} = Cavebot.Route.append(Cavebot.Route.new("rota de teste"), {10, 12, 5})
    :ok = Cavebot.Store.add(route)

    assert :ok =
             BotSupervisor.start_all(
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

    assert status.cavebot.state != :idle
    assert status.cavebot.route == "rota de teste"
    # the cavebot OWNS combat's run/halt — start_all must not arm it directly
    assert status.combat.state == :idle
    assert status.fishing.state == :idle
    assert Pokex.Bots.MiniGame.Worker.status(servers.mini_game).state == :off

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
  test "emergency_escape sem escada calibrada: trava, para e broadcasta mesmo assim", %{
    tmp_dir: tmp
  } do
    alias Pokex.Bots.InputGate

    # scope home to an empty dir so Calibration.load fails → :not_calibrated
    Application.put_env(:pokex, :home_dir, tmp)

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
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
        # only the PILOT can leave a Space held — the safe default never presses
        mini_game_mode: "auto"
      },
      fn {k, v} -> Settings.put(k, v) end
    )

    # geometry matching the shared 220x220 scene fixture
    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: 220,
      screen_h: 220,
      water_point: {100, 100},
      glow_region: {0, 0, 20, 20},
      battle_region: {0, 0, 20, 20},
      arena_region: {0, 0, 220, 220},
      neutral_point: {100, 100}
    })

    # fish above the capsule -> the player holds Space to chase it
    game = Pokex.PngFixtures.mini_game_scene!(tmp, "hold.png", fish: 40..54, capsule: 100..114)
    Agent.stop(Pokex.Rig.Fake)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, game}]})

    assert :ok = Pokex.Bots.MiniGame.Worker.run(mini_game)
    wait_for(fn -> {:key_down, "space"} in Pokex.Rig.Fake.calls() end)

    # exactly the Guardian's on_panic closure (stop_all/5)
    assert :ok = BotSupervisor.stop_all(fishing, combat, catcher, mini_game, player_support)

    assert {:key_up, "space"} in Pokex.Rig.Fake.calls()
    assert Pokex.Bots.MiniGame.Worker.status(mini_game).state == :off
  end

  # CARACTERIZAÇÃO (Etapa 0 do plano de consolidação, alvo da Frente 1).
  # Duas telas fazem "este worker está RODANDO?" por esta função (o pill do
  # header e os botões do painel), e a resposta ATUAL tem uma pegadinha
  # documentada desde o PR #86: os estados de PARADA do cavebot (:blocked,
  # :stuck, :fight_stalled) contam como ATIVO — um pill que consultasse o
  # cavebot por aqui pintaria de verde um bot morto. Hoje ninguém morde porque
  # o header só olha pesca e combate; quem for ligar a caçada no indicador
  # global (Frente 1, snapshot único de sessão) precisa resolver ESTE teste.
  @tag :tmp_dir
  test "CARACTERIZAÇÃO: active?/1 — e a pegadinha dos estados de parada do cavebot" do
    for parado <- [:idle, :off, :ocupado] do
      refute BotSupervisor.active?(parado)
      refute BotSupervisor.active?(%{state: parado})
    end

    for rodando <- [:pescando, :hunting, :walking, :fighting, :watching] do
      assert BotSupervisor.active?(rodando)
    end

    # a pegadinha: parado-com-motivo é "ativo" para esta função
    for parada_do_cavebot <- [:blocked, :stuck, :fight_stalled] do
      assert BotSupervisor.active?(parada_do_cavebot)
    end
  end

  # FRENTE 1: os funis de produção são ORDENS — todo Iniciar/Parar/pânico/
  # logout/freio passa por stop_all/0 ou start_all/0, e cada um muda a geração.
  # É o bump daqui que mata a retomada pendente do Focus quando qualquer ordem
  # chega entre a perda e a volta do foco.
  @tag :tmp_dir
  test "FRENTE 1: stop_all/0 e start_all/0 mudam a geração — até um Iniciar que falha" do
    antes = Pokex.Bots.Session.generation()

    :ok = BotSupervisor.stop_all()
    depois_do_stop = Pokex.Bots.Session.generation()
    assert depois_do_stop > antes

    # o RESULTADO do Iniciar não importa pra geração: sucesso ou preflight
    # falhado, a intenção foi expressa e uma retomada pendente de antes dela
    # não pode sobreviver. (No env de teste ele SOBE a frota de verdade contra
    # o Rig fake — parar na sequência é obrigatório, ou o worker global fica
    # tickando contra um sensor morto pelo resto da suíte.)
    on_exit(fn -> BotSupervisor.stop_all() end)
    _resultado = BotSupervisor.start_all()
    assert Pokex.Bots.Session.generation() > depois_do_stop

    :ok = BotSupervisor.stop_all()
  end

  @tag :tmp_dir
  test "FRENTE 1: hold_for_focus devolve a geração da própria pausa" do
    generation = BotSupervisor.hold_for_focus()

    assert is_integer(generation)
    assert generation == Pokex.Bots.Session.generation()
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
