defmodule Pokex.Bots.Catcher.WorkerTest.FakeBody do
  use GenServer

  # `sleep_ms` makes a perform take real time. The sweep tests need it: with an
  # instant body the whole sweep drains before a halt sent from the test process
  # can land, and "the halt stopped it" would be a race, not an assertion.
  def start_link(test, sleep_ms \\ 0), do: GenServer.start_link(__MODULE__, {test, sleep_ms})
  @impl true
  def init(state), do: {:ok, state}
  @impl true
  def handle_call({:perform, actions, priority, _at}, _from, {test, sleep_ms} = state) do
    if sleep_ms > 0, do: Process.sleep(sleep_ms)
    send(test, {:performed, priority, actions})
    {:reply, :ok, state}
  end
end

defmodule Pokex.Bots.Catcher.WorkerTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Catcher.CorpseLibrary
  alias Pokex.Bots.Catcher.Worker
  alias Pokex.Bots.Catcher.WorkerTest.FakeBody
  alias Pokex.Bots.InputGate
  alias Pokex.Calibration
  alias Pokex.Perception.WorldState
  alias Pokex.Rig.Fake
  alias Pokex.Settings
  alias Pokex.SettingsStash

  # A SLOT ON THE BLACKBOARD THAT ONLY THE TESTS WRITE. `:corpses` was a real fact
  # once; naming the staging slot after a RETIRED fact reads like production still
  # publishes it.
  @staged_scan :catcher_test_scan

  setup %{tmp_dir: tmp} do
    # one shared blackboard: start from an empty world, never from the last test's
    WorldState.clear()

    Application.put_env(:pokex, :home_dir, tmp)
    mode = Settings.get(:player_mode)
    capture_enabled = Settings.get(:capture_enabled)

    on_exit(fn ->
      Pokex.TestHome.restore()
      Settings.put(:player_mode, mode)
      Settings.put(:capture_enabled, capture_enabled)
      :ets.delete(:pokex_world, @staged_scan)
    end)

    Settings.put(:player_mode, "still")

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: 1000,
      screen_h: 700,
      tile_px: 100,
      water_point: {400, 300},
      glow_region: {0, 0, 20, 20},
      battle_region: {900, 0, 80, 400},
      neutral_point: {500, 500}
    })

    {:ok, _} = Fake.start_link(%{})
    {:ok, body} = FakeBody.start_link(self())

    # The injected scanner reads the SAME WorldState the tests populate via world!/1 —
    # kill and confirmation wakes see exactly the staged scene (production defaults to
    # the real SpotScan).
    scanner = fn ->
      case WorldState.get(@staged_scan, 60_000, System.monotonic_time(:millisecond)) do
        {:ok, obs} -> obs
        _nada -> nil
      end
    end

    worker = start_supervised!({Worker, name: nil, body: body, scanner: scanner})
    :ok = Worker.run(worker)
    %{worker: worker}
  end

  defp corpses_obs(points) do
    %{scanning?: true, corpses: points, captured_at: System.monotonic_time(:millisecond)}
  end

  # PELO CAMINHO QUE A PRODUÇÃO USA. Isto mandava `{:world, :corpses, obs}` —
  # o feed do chão, APOSENTADO em 30/07 e desde então inalcançável: vinte
  # testes exercitavam um handler que o bot nunca chama. O `{:kill}` é o
  # gatilho de verdade, e o scanner injetado lê a mesma cena do quadro-negro.
  defp world!(worker, obs) do
    WorldState.put(@staged_scan, obs, obs.captured_at)
    send(worker, {:kill})
  end

  # O olho (CrowdWatch) publica cada leitura no tópico do cérebro; o worker só
  # precisa dos pontos de quem estava de pé.
  # A lista do cérebro zerada (`:situation`): o único momento em que a bola comum
  # sai numa caçada.
  defp list_empty,
    do: WorldState.put(:situation, %{enemies: 0}, System.monotonic_time(:millisecond))

  defp saw_standing(worker, points),
    do: send(worker, {:crowd, %{read?: true, hostiles: Enum.map(points, &%{point: &1})}})

  @tag :tmp_dir
  test "pending_corpses rides the snapshot: 1 with a ball in flight, 0 once resolved", %{
    worker: worker
  } do
    assert Worker.status(worker).pending_corpses == 0

    world!(worker, corpses_obs([{150, 250}]))
    assert_receive {:performed, :high, [{:move, {150, 250}} | _]}, 1_000
    assert Worker.status(worker).pending_corpses == 1

    gone = corpses_obs([])
    gone = %{gone | captured_at: gone.captured_at + 2_000}
    world!(worker, gone)
    assert eventually(fn -> Worker.status(worker).pending_corpses == 0 end, 2_000)
  end

  @tag :tmp_dir
  test "a corpse observation makes it throw a ball at :high", %{worker: worker} do
    world!(worker, corpses_obs([{130, 224}]))
    assert_receive {:performed, :high, [{:move, {130, 224}} | _]}, 1_000
    assert Worker.status(worker).counters.throws == 1
  end

  # He keeps more than one kind of ball on the hotbar: F1 ordinary, F2 better at
  # water types. The aim already knows WHO is lying there, so the ball can be
  # chosen instead of always spending the same one.
  @tag :tmp_dir
  test "the corpse's name decides WHICH ball key is pressed", %{worker: worker} do
    SettingsStash.stash!(
      ball_key: "f1",
      ball_types: [
        %{"key" => "f1", "name" => "Poké Ball"},
        %{"key" => "f2", "name" => "Aquática"}
      ]
    )

    Phoenix.PubSub.subscribe(Pokex.PubSub, "catcher")

    # A ESCOLHA MORA NO CORPO ENSINADO: o nome que a mira devolve é o mesmo que
    # o acervo guarda, então é lá que a bola é escolhida.
    {:ok, 1} =
      CorpseLibrary.add("Tentacool shiny", %Pokex.Vision.Frame{
        width: 4,
        height: 4,
        rgba: :binary.copy(<<40, 200, 190, 255>>, 16)
      })

    :ok = CorpseLibrary.set_ball("tentacool-shiny", "f2")

    obs =
      corpses_obs([{130, 224}])
      |> Map.put(:known, %{{130, 224} => %{name: "Tentacool shiny", score: 0.9}})

    world!(worker, obs)

    assert_receive {:performed, :high, actions}, 1_000
    assert {:press, "f2"} in actions
    assert_log_eventually("🔴 Aquática (f2) para Tentacool shiny")
  end

  @tag :tmp_dir
  test "a corpse that chose no ball of its own keeps the ordinary one, quietly", %{worker: worker} do
    SettingsStash.stash!(
      ball_key: "f1",
      ball_types: [
        %{"key" => "f1", "name" => "Poké Ball"},
        %{"key" => "f2", "name" => "Aquática"}
      ]
    )

    obs =
      corpses_obs([{130, 224}])
      |> Map.put(:known, %{{130, 224} => %{name: "Rattata", score: 0.9}})

    world!(worker, obs)

    assert_receive {:performed, :high, actions}, 1_000
    assert {:press, "f1"} in actions
  end

  @tag :tmp_dir
  test "the throw log names which pokemon the library recognized", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "catcher")

    obs =
      corpses_obs([{130, 224}])
      |> Map.put(:known, %{{130, 224} => %{name: "Corsola", score: 0.87}})

    world!(worker, obs)

    assert_receive {:performed, :high, [{:move, {130, 224}} | _]}, 1_000
    assert_log_eventually("🎯 Corsola reconhecido (87%)")
  end

  # PIXEL NÃO É PORCENTAGEM. A mira por cor não tem semelhança nenhuma pra
  # contar: tem a contagem de pixels da cor, e ela ia pro mesmo campo do
  # reconhecimento por foto — 1,2 milhão de pixels viravam "(120000000%)".
  # A BOLA COMUM NÃO É A BOLA DO SHINY. Todo arremesso carimbava "bola" na
  # prateleira do shiny e zerava a pendência, então uma bola em corpo comum da
  # varredura fechava a caçada do corpo do shiny antes de alguém tê-lo visto.
  @tag :tmp_dir
  test "an ordinary ball does not close the shiny's entry", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "catcher")
    send(worker, {:shiny_seen, %{name: "Electrode shiny", px: 80, point: {900, 900}}})

    world!(worker, corpses_obs([{130, 224}]))
    assert_receive {:performed, :high, [{:move, {130, 224}} | _]}, 1_000

    assert Worker.status(worker).shiny_pending?, "a caçada do shiny segue aberta"
  end

  # A ESTRELA É DA LEITURA, não do estado. Com a varredura e a mira abertas ao
  # mesmo tempo, marcar pelo estado do worker mandaria a bola de um corpo comum
  # pra dentro da história do shiny — que é o vazamento que a estrela veio
  # tapar.
  @tag :tmp_dir
  test "an ordinary sweep ball is not starred", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "catcher")

    world!(worker, corpses_obs([{130, 224}]))

    assert_receive {:performed, :high, [{:move, {130, 224}} | _]}, 1_000
    # o prefixo colado prova a ausência da estrela: com ela a linha seria
    # "captura: 🌟 bola em 130,224"
    assert_log_eventually("captura: bola em 130,224")
  end

  @tag :tmp_dir
  test "the colour aim logs pixels, not a percentage", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "catcher")

    obs =
      corpses_obs([{130, 224}])
      |> Map.put(:known, %{{130, 224} => %{name: "Charizard preto", px: 1_200_000}})

    world!(worker, obs)

    assert_receive {:performed, :high, [{:move, {130, 224}} | _]}, 1_000
    assert_log_eventually("🎯 Charizard preto reconhecido pela cor (1200000 px)")
  end

  @tag :tmp_dir
  test "run announces the library — empty is a siren, not silence", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "catcher")

    :ok = Worker.run(worker)

    assert_receive {:rule_alarm, :capture, msg}, 1_000
    assert msg =~ "acervo de corpos VAZIO"
  end

  defp assert_log_eventually(fragment, timeout \\ 1_000) do
    receive do
      {:catcher_log, :macro, msg} ->
        if msg =~ fragment, do: :ok, else: assert_log_eventually(fragment, timeout)
    after
      timeout -> flunk("nenhum catcher_log contendo #{inspect(fragment)} chegou")
    end
  end

  # The feed keeps re-putting fresh empty observations WITHOUT broadcasting when nothing
  # changed — only the worker's wake polling can find them.
  @tag :tmp_dir
  test "polling alone confirms a vanished corpse (no further events)", %{worker: worker} do
    world!(worker, corpses_obs([{130, 224}]))
    assert_receive {:performed, :high, _}, 1_000

    spawn(fn ->
      for _i <- 1..8 do
        Process.sleep(150)
        obs = corpses_obs([])
        WorldState.put(@staged_scan, obs, obs.captured_at)
      end
    end)

    assert eventually(fn -> Worker.status(worker).counters.captures == 1 end, 3_000)
  end

  @tag :tmp_dir
  test "a kill event triggers an immediate world re-read", %{worker: _worker} do
    obs = corpses_obs([{140, 230}])
    WorldState.put(@staged_scan, obs, obs.captured_at)
    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill})

    assert_receive {:performed, :high, [{:move, {140, 230}} | _]}, 1_000
  end

  @tag :tmp_dir
  test "movimento mode never acts", %{worker: worker} do
    Settings.put(:player_mode, "moving")
    :ok = Worker.mode_changed(worker)
    assert Worker.status(worker).state == :manual

    world!(worker, corpses_obs([{130, 224}]))
    refute_receive {:performed, _p, _a}, 300

    Settings.put(:player_mode, "still")
    :ok = Worker.mode_changed(worker)
    assert Worker.status(worker).state == :armed
  end

  @tag :tmp_dir
  test "mode_changed on a HALTED worker never re-attaches the feed", %{worker: worker} do
    :ok = Worker.halt(worker)
    assert Worker.status(worker).state == :idle

    :ok = Worker.mode_changed(worker)
    world!(worker, corpses_obs([{130, 224}]))
    refute_receive {:performed, _p, _a}, 300
    assert Worker.status(worker).state == :idle
  end

  @tag :tmp_dir
  # A corpse observation arriving mid-fight must be held: the stationary blob the detector
  # sees might just be the live, tile-locked enemy sprite.
  test "a fight in progress holds all throws", %{worker: worker} do
    send(worker, {:combat, %{state: :fighting, counters: %{}, error: nil, locked_row: 0}})

    world!(worker, corpses_obs([{150, 250}]))
    refute_receive {:performed, _p, _a}, 300
    assert Worker.status(worker).hold_reason == "esperando fim da luta"

    fresh = corpses_obs([{150, 250}])
    WorldState.put(@staged_scan, fresh, fresh.captured_at)
    send(worker, {:combat, %{state: :hunting, counters: %{}, error: nil, locked_row: nil}})

    assert_receive {:performed, :high, [{:move, {150, 250}} | _]}, 1_000
    assert Worker.status(worker).hold_reason == nil
    assert %{text: "bola arremessada" <> _, at: at} = Worker.status(worker).last_action
    assert is_integer(at)
  end

  @tag :tmp_dir
  # A throw mid mini-game would move the cursor off the capsule the player is driving.
  test "the mini-game fact freezes throws; the next event after it clears acts", %{
    worker: worker
  } do
    WorldState.put(
      :mini_game,
      %{playing?: true, confidence: 1.0},
      System.monotonic_time(:millisecond)
    )

    on_exit(fn -> WorldState.forget(:mini_game) end)

    obs = corpses_obs([{130, 224}])
    WorldState.put(@staged_scan, obs, obs.captured_at)
    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill})
    refute_receive {:performed, _p, _a}, 300

    WorldState.forget(:mini_game)
    world!(worker, corpses_obs([{130, 224}]))
    assert_receive {:performed, :high, [{:move, {130, 224}} | _]}, 1_000
  end

  # A post-relearn warmup frame (scanning?: false) must not read as "corpse vanished" —
  # it would falsely confirm a capture and aim the next queued throw at the old spot.
  @tag :tmp_dir
  test "relearn resets pending state", %{worker: worker} do
    world!(worker, corpses_obs([{160, 260}]))
    assert_receive {:performed, :high, [{:move, {160, 260}} | _]}, 1_000
    assert Worker.status(worker).counters.throws == 1

    :ok = Worker.relearn(worker)

    future_ms = System.monotonic_time(:millisecond) + 2_000
    warmup = %{scanning?: false, corpses: [], captured_at: future_ms}
    world!(worker, warmup)

    refute_receive {:performed, _p, _a}, 300
    assert Worker.status(worker).counters.captures == 0
  end

  @tag :tmp_dir
  test "run re-seeds combat engagement from live status (stale engaged flag can't stick)",
       %{worker: worker} do
    send(worker, {:combat, %{state: :fighting, counters: %{}, error: nil, locked_row: 0}})
    :ok = Worker.halt(worker)
    :ok = Worker.run(worker)

    world!(worker, corpses_obs([{130, 224}]))
    assert_receive {:performed, :high, [{:move, {130, 224}} | _]}, 1_000
  end

  @tag :tmp_dir
  test "capture_enabled false: balls never, feed never attaches",
       %{worker: worker} do
    Settings.put(:capture_enabled, false)
    :ok = Worker.mode_changed(worker)

    obs = corpses_obs([{130, 224}])
    WorldState.put(@staged_scan, obs, obs.captured_at)
    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill})

    refute_receive {:performed, _, [{:move, _} | _]}, 400

    world!(worker, corpses_obs([{140, 230}]))
    refute_receive {:performed, _, [{:move, _} | _]}, 300
  end

  @tag :tmp_dir
  test "every scan becomes a feed line — and the session scoreboard advances", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "catcher")

    world!(worker, corpses_obs([{130, 224}]))
    assert_receive {:performed, :high, [{:move, _} | _]}, 1_000

    assert %{scans: v, with_target: c} = Worker.status(worker).counters
    assert v > 0, "a varredura tem que ser contada"
    assert c > 0, "esta varredura achou alvo"
  end

  @tag :tmp_dir
  test "a blind scan is counted and narrated, and never confirms a ball", %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "catcher")

    world!(worker, corpses_obs([{130, 224}]))
    assert_receive {:performed, :high, [{:move, {130, 224}} | _]}, 1_000
    assert Worker.status(worker).pending_corpses == 1

    blind = %{
      scanning?: false,
      corpses: [],
      known: %{},
      captured_at: System.monotonic_time(:millisecond) + 5_000,
      reason: :outside_arena
    }

    world!(worker, blind)

    assert_log_eventually("cego")

    assert Worker.status(worker).pending_corpses == 1
    assert Worker.status(worker).counters.blind > 0
  end

  @tag :tmp_dir
  # The first post-kill frame is usually dirty (death animation, own pokemon on top)
  # while the corpse lasts minutes — the worker re-scans on its own with no new event.
  test "a kill with no target re-triggers the scan — the corpse gets more chances", %{
    worker: _worker
  } do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    scanner = fn ->
      Agent.update(counter, &(&1 + 1))

      %{
        scanning?: true,
        corpses: [],
        known: %{},
        captured_at: System.monotonic_time(:millisecond)
      }
    end

    {:ok, body} = FakeBody.start_link(self())
    {:ok, worker} = Worker.start_link(name: nil, body: body, scanner: scanner)
    :ok = Worker.run(worker)

    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill})

    assert eventually(fn -> Agent.get(counter, & &1) >= 2 end, 1_500)

    GenServer.stop(worker)
  end

  @tag :tmp_dir
  # Rig.Mac.gated/1 returns :ok even when it SUPPRESSES — acting and checking afterwards
  # would count a ball that never flew; the gate is asked BEFORE, skipping the whole step.
  test "gate closed: the ball is held, not counted — and Logic never learns of it", %{
    worker: worker
  } do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "catcher")
    InputGate.set_focus_ok(false)
    on_exit(fn -> InputGate.set_focus_ok(true) end)

    world!(worker, corpses_obs([{130, 224}]))

    refute_receive {:performed, _p, [{:move, _} | _]}, 300
    assert_log_eventually("SEGURADA")

    assert Worker.status(worker).counters.throws == 0
    assert Worker.status(worker).pending_corpses == 0

    InputGate.set_focus_ok(true)
    world!(worker, corpses_obs([{130, 224}]))
    assert_receive {:performed, :high, [{:move, {130, 224}} | _]}, 1_000
  end

  @tag :tmp_dir
  # Field 2026-07-30: the bot ran while capture was silently off — the only
  # clue was a subtle pill that read as normal state.
  test "capture disabled says so by name — in the hold reason and in a start alarm",
       %{worker: worker} do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "catcher")
    Settings.put(:capture_enabled, false)
    :ok = Worker.mode_changed(worker)

    assert Worker.status(worker).hold_reason == "captura DESLIGADA — só saque"

    :ok = Worker.run(worker)
    assert_receive {:rule_alarm, :capture, msg}, 1_000
    assert msg =~ "captura DESLIGADA"

    Settings.put(:capture_enabled, true)
    :ok = Worker.mode_changed(worker)
    assert Worker.status(worker).hold_reason == nil
  end

  @tag :tmp_dir
  # Space reaches the corpse on the tile where the kill landed, wherever he
  # happens to be standing at that instant — so walking must not cost him the
  # drops. Only the BALL needs the standing-still ground baseline.
  @tag :tmp_dir
  test "movimento: a kill never throws a ball", %{worker: worker} do
    Settings.put(:player_mode, "moving")
    :ok = Worker.mode_changed(worker)

    obs = corpses_obs([{140, 230}])
    WorldState.put(@staged_scan, obs, obs.captured_at)
    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill})

    refute_receive {:performed, _p, [{:move, _} | _]}, 300
  end

  @tag :tmp_dir
  test "producer order (kill first, snapshot second) still throws the ball", %{
    worker: worker
  } do
    send(worker, {:combat, %{state: :fighting, counters: %{}, error: nil, locked_row: 0}})

    obs = corpses_obs([{130, 224}])
    WorldState.put(@staged_scan, obs, obs.captured_at)

    Phoenix.PubSub.broadcast(Pokex.PubSub, Worker.kill_topic(), {:kill})

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "combat",
      {:combat, %{state: :hunting, counters: %{}, error: nil, locked_row: nil}}
    )

    assert_receive {:performed, :high, [{:move, {130, 224}} | _]}, 1_000
  end

  # --- Varredura cega ---------------------------------------------------------
  # A CADÊNCIA DA VARREDURA NÃO PODIA SER EXERCITADA. `sweep_auto_tick` era lido
  # CRU dentro do `arm_sweep/1` privado — o único da família sem porta por
  # instância —, então na suíte inteira o `sweep_timer` ficava nil pra sempre e
  # a regra escrita logo acima dele ("uma varredura segurada tem que tentar de
  # novo no ciclo seguinte, não calar até o próximo Iniciar") passava verde
  # mesmo se alguém a estreitasse pra só re-armar quando `sweep_enabled`.
  @tag :tmp_dir
  test "the sweep re-arms even when off: it does not go quiet until the next Start", %{
    tmp_dir: _tmp
  } do
    Settings.put(:sweep_enabled, false)

    {:ok, body} = FakeBody.start_link(self())

    worker =
      start_supervised!(
        {Worker, name: nil, body: body, scanner: fn -> nil end, auto_tick: true},
        id: :catcher_auto_tick
      )

    :ok = Worker.run(worker)
    assert :sys.get_state(worker).sweep_timer, "não armou no arranque"

    send(worker, :sweep)

    assert :sys.get_state(worker).sweep_timer, "calou depois de uma passada segurada"
  end

  # The blind sweep: no detector, no library, a ball at every tile in reach.
  # It exists because the aimed capture MISSES (Lucas, 2026-08-05: "atualmente
  # eu tô vendo ele perder muito pokémon"), so what it must prove here is that
  # it throws at every tile — and that every gate still stops it.
  describe "varredura cega" do
    setup do
      SettingsStash.stash!(
        sweep_radius_tiles: 1,
        sweep_side: "square",
        sweep_enabled: false
      )

      Calibration.save(%Calibration{
        scale: 1.0,
        screen_w: 1000,
        screen_h: 700,
        tile_px: 100,
        water_point: {400, 300},
        glow_region: {0, 0, 20, 20},
        battle_region: {900, 0, 80, 400},
        neutral_point: {500, 500},
        player_point: {500, 350}
      })

      # the verdict of a sweep comes back as a broadcast, never as a reply
      Phoenix.PubSub.subscribe(Pokex.PubSub, "catcher")
      :ok
    end

    # "Captura desligada" alarms "nenhuma Pokébola será arremessada" on the
    # panel. The sweep used to read only its own switch and kept throwing one at
    # every tile anyway — a promise on screen the code did not keep.
    @tag :tmp_dir
    test "with capture off, no ball flies — not even a blind one", %{worker: worker} do
      SettingsStash.stash!(capture_enabled: false)

      :ok = Worker.sweep_now(worker)

      assert_receive {:sweep_result, "não varreu: a captura está desligada"}, 1_000
      refute Enum.any?(Pokex.Rig.Fake.calls(), &match?({:press, "f1"}, &1))
    end

    @tag :tmp_dir
    test "throws the ball at every tile around the character, nearest ring first", %{
      worker: worker
    } do
      :ok = Worker.sweep_now(worker)
      assert_receive {:sweep_result, "varrendo 8 tile(s)…"}, 1_000

      for point <- [
            {400, 250},
            {500, 250},
            {600, 250},
            {400, 350},
            {600, 350},
            {400, 450},
            {500, 450},
            {600, 450}
          ] do
        # :normal, not :high — the sweep is a background guarantee and must
        # never get ahead of the rod or of a ball aimed at a real corpse
        assert_receive {:performed, :normal, [{:move, ^point} | rest]}, 1_000
        assert {:press, "f1"} in rest
      end

      assert Worker.status(worker).sweep.balls == 8
      assert Worker.status(worker).sweep.pending == 0
    end

    @tag :tmp_dir
    test "the tile where his own Pokémon stands is spared", %{worker: worker} do
      Calibration.save(%Calibration{
        scale: 1.0,
        screen_w: 1000,
        screen_h: 700,
        tile_px: 100,
        water_point: {400, 300},
        glow_region: {0, 0, 20, 20},
        battle_region: {900, 0, 80, 400},
        neutral_point: {500, 500},
        player_point: {500, 350},
        pokemon_spot_point: {600, 350}
      })

      :ok = Worker.sweep_now(worker)
      assert_receive {:sweep_result, "varrendo 7 tile(s)…"}, 1_000
      refute_receive {:performed, :normal, [{:move, {600, 350}} | _]}, 300
    end

    @tag :tmp_dir
    # The cadence tick is a heartbeat: it always fires, and it is the TICK that
    # reads the switch. That is what lets the settings screen flip the switch
    # without asking this process anything.
    test "the cadence sweeps only with the switch on — the test button always does", %{
      worker: worker
    } do
      send(worker, :sweep)
      refute_receive {:performed, :normal, [{:move, _} | _]}, 300

      Settings.put(:sweep_enabled, true)
      send(worker, :sweep)
      assert_receive {:performed, :normal, [{:move, _} | _]}, 1_000
    end

    @tag :tmp_dir
    test "a fight in progress holds the sweep, and says which gate it was", %{worker: worker} do
      send(worker, {:combat, %{state: :fighting, counters: %{}, error: nil, locked_row: 0}})

      :ok = Worker.sweep_now(worker)
      assert_receive {:sweep_result, "não varreu: luta em andamento"}, 1_000
      refute_receive {:performed, :normal, _actions}, 300
    end

    @tag :tmp_dir
    test "walking holds the sweep: the grid hangs off where the character is standing", %{
      worker: worker
    } do
      Settings.put(:player_mode, "moving")

      :ok = Worker.sweep_now(worker)
      assert_receive {:sweep_result, "não varreu: a varredura é do modo Parado"}, 1_000
    end

    @tag :tmp_dir
    test "the mini-game holds the sweep", %{worker: worker} do
      WorldState.put(
        :mini_game,
        %{playing?: true, confidence: 1.0},
        System.monotonic_time(:millisecond)
      )

      on_exit(fn -> WorldState.forget(:mini_game) end)

      :ok = Worker.sweep_now(worker)
      assert_receive {:sweep_result, "não varreu: mini-game em jogo"}, 1_000
    end

    @tag :tmp_dir
    test "the game out of focus holds the sweep", %{worker: worker} do
      InputGate.set_focus_ok(false)
      on_exit(fn -> InputGate.set_focus_ok(true) end)

      :ok = Worker.sweep_now(worker)
      assert_receive {:sweep_result, text}, 1_000
      assert text =~ "foco"
    end

    @tag :tmp_dir
    # THE CRASH OF 2026-08-05: this was a GenServer.call from the LiveView's
    # handle_event. This worker parks on captures the broker can hold for
    # seconds, the 5s call timed out, and the exit took the whole page down.
    # A busy worker must cost the caller nothing.
    test "asking for a sweep never waits on a busy worker", %{tmp_dir: tmp} do
      Application.put_env(:pokex, :home_dir, tmp)
      # 1.5s per action parks the worker exactly like a slow capture does
      {:ok, body} = FakeBody.start_link(self(), 1_500)

      worker =
        start_supervised!({Worker, name: nil, body: body, scanner: fn -> nil end},
          id: :stuck_body
        )

      :ok = Worker.run(worker)
      :ok = Worker.sweep_now(worker)
      assert_receive {:sweep_result, "varrendo" <> _}, 1_000

      {elapsed_us, reply} = :timer.tc(fn -> Worker.sweep_now(worker) end)

      assert reply == :ok
      assert elapsed_us < 200_000, "the ask blocked on the worker — that is the crash"
    end

    @tag :tmp_dir
    # 80 tiles is ~15s of Body time. A sweep that could not be cut short would
    # be 15s in which nothing else — a halt, the panic corner — got a turn.
    test "halting drops the tiles still owed", %{tmp_dir: tmp} do
      Application.put_env(:pokex, :home_dir, tmp)
      {:ok, body} = FakeBody.start_link(self(), 30)

      worker =
        start_supervised!({Worker, name: nil, body: body, scanner: fn -> nil end}, id: :slow_body)

      :ok = Worker.run(worker)

      :ok = Worker.sweep_now(worker)
      assert_receive {:performed, :normal, _first_tile}, 1_000

      :ok = Worker.halt(worker)

      assert Worker.status(worker).sweep.pending == 0
      assert drain_performed() < 7, "the halt did not stop the sweep"
    end
  end

  defp drain_performed(count \\ 0) do
    receive do
      {:performed, _priority, _actions} -> drain_performed(count + 1)
    after
      100 -> count
    end
  end

  # -- the shiny aim -----------------------------------------------------------
  #
  # The guard saw a shiny; the Catcher looks for its corpse by colour on its own
  # timer, in ANY player_mode, and hands the point to the same Logic.

  defp aim_obs(points) do
    cands = Enum.map(points, &%{name: "Electrode shiny", px: 80, point: &1, in_frame: &1})

    Pokex.Bots.Catcher.ShinyAim.obs(
      cands,
      {0, 0, 300, 300},
      System.monotonic_time(:millisecond)
    )
  end

  defp stage_aim(points),
    do: WorldState.put(:shiny_aim, aim_obs(points), System.monotonic_time(:millisecond))

  defp start_hunt_worker(extra \\ []) do
    Settings.put(:player_mode, "hunt")
    SettingsStash.stash!(special_color_scan_ms: 50)
    Phoenix.PubSub.subscribe(Pokex.PubSub, "catcher")
    {:ok, body} = FakeBody.start_link(self())

    # a fresh captured_at per look: the Logic drops an observation it already judged
    aimer = fn ->
      case WorldState.get(:shiny_aim, 60_000, System.monotonic_time(:millisecond)) do
        {:ok, obs} -> %{obs | captured_at: System.monotonic_time(:millisecond)}
        _nada -> nil
      end
    end

    worker =
      start_supervised!(
        {Worker, [name: nil, body: body, aimer: aimer] ++ extra},
        id: :hunt_worker
      )

    :ok = Worker.run(worker)
    worker
  end

  # A RODADA FECHOU: O CORPO DO SHINY É PROCURADO PELA COR TAMBÉM. Em 11/09 o
  # vigia não viu o Shiny Golem de pé (pilha de nove, tom apertado) mas viu o
  # corpo — "1 mancha da cor sem bicho embaixo" — e ninguém pediu a bola.
  @tag :tmp_dir
  test "at the capture cue, an armed colour rule looks for the shiny's corpse by colour" do
    worker = start_hunt_worker(scanner: fn -> nil end)
    arm_colour_rule("Shiny Golem")

    WorldState.put(:orders, %{route: :hold}, System.monotonic_time(:millisecond))
    list_empty()
    stage_aim([{116, 116}])

    Phoenix.PubSub.subscribe(Pokex.PubSub, "shiny")
    send(worker, {:capture_now})

    assert_receive {:performed, :high, [{:move, {116, 116}} | _]}, 3_000
    assert_log_eventually("🌟 bola em 116,116")
    # …and the header's banner hears the ball
    assert_receive {:shiny_ball, %{point: {116, 116}}}, 1_000
  end

  # THE IDENTITY TRAVELS WITH THE BAR (plan §3.5, `Catcher.Trail`). 11/09 09:13:
  # the Shiny Golem's corpse had none of the live colour; where its bar vanished
  # is where the ball goes — no colour rule needed, and it follows him walking.
  @tag :tmp_dir
  test "the shiny's bar followed until it falls buys the ball at the cue, with no colour at all" do
    worker = start_hunt_worker(scanner: fn -> nil end)
    Phoenix.PubSub.subscribe(Pokex.PubSub, "shiny")

    # the eye sees the shiny standing (the guard's blob on it), then it walks
    me = {500, 350}

    seen = fn point, extra ->
      %{read?: true, me: me, hostiles: [Map.merge(%{point: point}, extra)], pet: nil}
    end

    shiny = %{special?: true, special_name: "Shiny Golem", special_px: 394}

    send(worker, {:crowd, seen.({500, 150}, shiny)})
    send(worker, {:crowd, seen.({550, 200}, %{})})
    send(worker, {:crowd, seen.({600, 250}, %{})})

    # …and its bar is gone: three looks without it is a death
    for _ <- 1..3, do: send(worker, {:crowd, %{read?: true, me: me, hostiles: [], pet: nil}})

    assert_log_eventually("Shiny Golem caiu em 600,250")

    WorldState.put(:orders, %{route: :hold}, System.monotonic_time(:millisecond))
    list_empty()
    send(worker, {:capture_now})

    assert_log_eventually("bola na âncora do Shiny Golem em 600,250")
    assert_receive {:performed, :high, [{:move, {600, 250}} | _]}, 3_000
    assert_receive {:shiny_ball, %{point: {600, 250}, name: "Shiny Golem"}}, 1_000
  end

  # MEIO TILE. 17:25:59 of 11/09: the guard's blob (the art's centre, half a
  # tile under the bar) sat 75 px from the creature ABOVE and 76 px from the
  # right one, and two tracks fell "hunted" — the neighbour among them.
  @tag :tmp_dir
  test "the guard's blob between two stacked creatures hunts the one under its own bar" do
    worker = start_hunt_worker(scanner: fn -> nil end)
    Phoenix.PubSub.subscribe(Pokex.PubSub, "shiny")
    me = {500, 350}
    # tile 100 in this calibration: bars at y=100 and y=200, bodies at 200 and 300
    upper = %{point: {500, 200}}
    lower = %{point: {500, 300}}
    look = fn hostiles -> %{read?: true, me: me, hostiles: hostiles, pet: nil} end

    send(worker, {:crowd, look.([upper, lower])})
    # the sparkle beside the UPPER creature's name: its art's centre is bar + half a tile
    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "shiny",
      {:shiny_on_screen, %{vistos: [%{name: "Shiny (brilho)", px: 60, point: {500, 150}}]}}
    )

    send(worker, {:crowd, look.([upper, lower])})
    assert %{trail: %{hunted: %{screen: {500, 200}}}} = Worker.status(worker)

    # the upper one falls; the lower one stands: one anchor, on the upper one
    for _ <- 1..3, do: send(worker, {:crowd, look.([lower])})
    assert_log_eventually("Shiny (brilho) caiu em 500,200")
    assert %{trail: %{anchors: [%{screen: {500, 200}}]}} = Worker.status(worker)
  end

  # THE ANCHOR'S BALL NEEDS NO COLOUR SESSION: 17:26:00 of 11/09, two anchors
  # announced and no ball, in silence. The shiny observation carries its own
  # licence, and a refusal is said out loud.
  @tag :tmp_dir
  test "with capture off, the anchor still buys the ball, and a refusal is said out loud" do
    Settings.put(:capture_enabled, false)
    worker = start_hunt_worker(scanner: fn -> nil end)
    me = {500, 350}
    shiny = %{special?: true, special_name: "Shiny Golem", special_px: 394}
    seen = fn hostiles -> %{read?: true, me: me, hostiles: hostiles, pet: nil} end

    send(worker, {:crowd, seen.([Map.merge(%{point: {600, 250}}, shiny)])})
    for _ <- 1..3, do: send(worker, {:crowd, seen.([])})
    assert_log_eventually("Shiny Golem caiu em 600,250")

    WorldState.put(:orders, %{route: :hold}, System.monotonic_time(:millisecond))
    list_empty()
    send(worker, {:capture_now})

    assert_log_eventually("bola na âncora do Shiny Golem em 600,250")
    assert_receive {:performed, :high, [{:move, {600, 250}} | _]}, 3_000

    SettingsStash.stash!(shiny_always_ball: false)
    send(worker, {:crowd, seen.([Map.merge(%{point: {700, 250}}, shiny)])})
    for _ <- 1..3, do: send(worker, {:crowd, seen.([])})
    assert_log_eventually("Shiny Golem caiu em 700,250")
    send(worker, {:capture_now})
    assert_log_eventually("a bola da âncora NÃO saiu")
    assert_log_eventually("a âncora ficou pra próxima hora da bola")
  end

  # THE BALL AT THE FALL. 19:16:48 of 11/09: the anchor was minted 3 ms after
  # the round's hora da bola had already run, and the next one never came (he
  # stopped at 19:16:52 with the corpse on the ground). The fall is the moment
  # the body is known; with the feet still, the ball goes right then.
  @tag :tmp_dir
  test "with the feet still, the ball flies at the fall without waiting for the cue" do
    worker = start_hunt_worker(scanner: fn -> nil end)
    Phoenix.PubSub.subscribe(Pokex.PubSub, "shiny")
    me = {500, 350}
    shiny = %{special?: true, special_name: "Shiny Golem", special_px: 394}
    seen = fn hostiles -> %{read?: true, me: me, hostiles: hostiles, pet: nil} end

    send(worker, {:crowd, seen.([Map.merge(%{point: {600, 250}}, shiny)])})
    # the round closed: the brain holds the feet and the list is empty
    WorldState.put(:orders, %{route: :hold}, System.monotonic_time(:millisecond))
    list_empty()
    for _ <- 1..3, do: send(worker, {:crowd, seen.([])})

    assert_log_eventually("Shiny Golem caiu em 600,250")
    assert_log_eventually("bola na âncora do Shiny Golem em 600,250")
    assert_receive {:performed, :high, [{:move, {600, 250}} | _]}, 3_000
    assert_receive {:shiny_ball, %{point: {600, 250}, name: "Shiny Golem"}}, 1_000
  end

  # 19:51:19 of 11/09: the corpse at 1268,768, the character standing beside
  # it, and "a lógica recusou 1 âncora(s)" — the round's own scan had stamped
  # its photo in the same millisecond, and the Logic's freshness gate ate the
  # anchor. The anchor is always newer than any photo the Logic has seen.
  @tag :tmp_dir
  test "the anchor's ball survives a scan stamped in the same instant" do
    ahead = fn ->
      %{
        scanning?: true,
        corpses: [],
        candidates: [],
        known: %{},
        region: {0, 0, 0, 0},
        captured_at: System.monotonic_time(:millisecond) + 50
      }
    end

    worker = start_hunt_worker(scanner: ahead)
    me = {500, 350}
    shiny = %{special?: true, special_name: "Shiny Golem", special_px: 394}
    seen = fn hostiles -> %{read?: true, me: me, hostiles: hostiles, pet: nil} end

    send(worker, {:crowd, seen.([Map.merge(%{point: {600, 250}}, shiny)])})
    for _ <- 1..3, do: send(worker, {:crowd, seen.([])})
    assert_log_eventually("Shiny Golem caiu em 600,250")

    WorldState.put(:orders, %{route: :hold}, System.monotonic_time(:millisecond))
    list_empty()
    send(worker, {:capture_now})

    assert_log_eventually("bola na âncora do Shiny Golem em 600,250")
    assert_receive {:performed, :high, [{:move, {600, 250}} | _]}, 3_000
  end

  @tag :tmp_dir
  test "walking, the fall says so and waits for the hora da bola" do
    worker = start_hunt_worker(scanner: fn -> nil end)
    me = {500, 350}
    shiny = %{special?: true, special_name: "Shiny Golem", special_px: 394}
    seen = fn hostiles -> %{read?: true, me: me, hostiles: hostiles, pet: nil} end

    send(worker, {:crowd, seen.([Map.merge(%{point: {600, 250}}, shiny)])})
    WorldState.put(:orders, %{route: :go}, System.monotonic_time(:millisecond))
    for _ <- 1..3, do: send(worker, {:crowd, seen.([])})

    assert_log_eventually("Shiny Golem caiu em 600,250")
    assert_log_eventually("a âncora caiu com a estrada andando")
    refute_receive {:performed, _p, _a}, 300
  end

  @tag :tmp_dir
  test "at the capture cue with no colour rule armed, no colour session opens" do
    worker = start_hunt_worker(scanner: fn -> nil end)

    WorldState.put(:orders, %{route: :hold}, System.monotonic_time(:millisecond))
    list_empty()
    stage_aim([{116, 116}])

    send(worker, {:capture_now})

    refute_receive {:performed, _p, _a}, 500
    refute Worker.status(worker).hold_reason == "mirando o corpo do shiny pela cor"
  end

  # THE SESSION SAYS WHAT IT SAW WHEN IT CLOSES. 11/09 09:13: the Shiny Golem's
  # corpse was on screen with zero pixels of the live tone, and the aim closed
  # without a word - nothing told that apart from a held look or a vetoed corpse.
  @tag :tmp_dir
  test "a colour session that finds nothing says what it saw when it closes" do
    worker = start_hunt_worker(scanner: fn -> nil end)
    arm_colour_rule("Shiny Golem")

    WorldState.put(:orders, %{route: :hold}, System.monotonic_time(:millisecond))
    list_empty()

    diag = %{biggest_px: 12, trigger: 120, above: 0, oversized: 0, refused: 0, bodied: 0}

    WorldState.put(
      :shiny_aim,
      Map.put(aim_obs([]), :diag, diag),
      System.monotonic_time(:millisecond)
    )

    send(worker, {:capture_now})

    assert_log_eventually(
      ~r/hora da bola — corpo do shiny pela cor: 3 foto\(s\) em .*maior mancha do tom 12 px \(gatilho 120\) · 0 acima do gatilho · nenhum corpo/
    )
  end

  defp arm_colour_rule(name) do
    :persistent_term.erase({Pokex.Vision.ColorRules, :cache})

    {:ok, %{"slug" => slug}} =
      Pokex.Vision.ColorRules.add(%{
        "name" => name,
        "colors" => [%{"rgb" => [18, 13, 19], "tol" => 2}],
        "min_px" => 120
      })

    :ok = Pokex.Vision.ColorRules.mark_proven(slug, 4)
  end

  @tag :tmp_dir
  test "in hunt mode a shiny sighting aims by colour and throws at :high" do
    worker = start_hunt_worker()
    stage_aim([{116, 116}])

    send(worker, {:shiny_seen, %{name: "Electrode shiny", px: 80, point: {116, 116}}})

    assert_receive {:performed, :high, [{:move, {116, 116}} | _]}, 3_000
    assert Worker.status(worker).counters.throws == 1
    assert_log_eventually("corpo do Electrode shiny")
    # A ESTRELA NA BOLA: a linha do arremesso é a mesma da varredura, e a tela
    # do Cave Bot só sabia separar as duas procurando a palavra "bola" —
    # pescando a caçada inteira pra dentro da história do shiny.
    assert_log_eventually("🌟 bola em 116,116")
  end

  @tag :tmp_dir
  test "the aim ignores the fight gate: a combat still engaged does not hold the shiny ball" do
    worker = start_hunt_worker()
    send(worker, {:combat, %{state: :fighting}})
    stage_aim([{116, 116}])

    send(worker, {:shiny_seen, %{name: "Electrode shiny", px: 80, point: {116, 116}}})

    assert_receive {:performed, :high, [{:move, {116, 116}} | _]}, 3_000
  end

  @tag :tmp_dir
  test "in hunt mode without a sighting nothing flies" do
    worker = start_hunt_worker()
    stage_aim([{116, 116}])

    refute_receive {:performed, _, _}, 500
    assert Worker.status(worker).counters.throws == 0
  end

  # The brain holds the feet on this fact (`Engine.Logic.hold_for_capture/2`):
  # "aiming" while the session lives, "not aiming" the moment it closes.
  @tag :tmp_dir
  test "the aim session publishes the :capture fact and clears it on close" do
    Application.put_env(:pokex, :shiny_aim_ttl_ms, 200)
    on_exit(fn -> Application.delete_env(:pokex, :shiny_aim_ttl_ms) end)

    worker = start_hunt_worker()
    stage_aim([])
    send(worker, {:shiny_seen, %{name: "Electrode shiny", px: 80, point: {116, 116}}})

    assert eventually(
             fn ->
               match?(
                 {:ok, %{aiming?: true}},
                 WorldState.get(:capture, 5_000, System.monotonic_time(:millisecond))
               )
             end,
             1_000
           )

    assert eventually(
             fn ->
               match?(
                 {:ok, %{aiming?: false, pending: 0}},
                 WorldState.get(:capture, 5_000, System.monotonic_time(:millisecond))
               )
             end,
             1_500
           )
  end

  @tag :tmp_dir
  test "the aim session ends when the shiny corpse is not found" do
    Application.put_env(:pokex, :shiny_aim_ttl_ms, 200)
    on_exit(fn -> Application.delete_env(:pokex, :shiny_aim_ttl_ms) end)

    worker = start_hunt_worker()
    stage_aim([])
    send(worker, {:shiny_seen, %{name: "Electrode shiny", px: 80, point: {116, 116}}})

    assert eventually(fn -> Worker.status(worker).aim? end, 500)
    assert_log_eventually("corpo não achado")
    assert eventually(fn -> not Worker.status(worker).aim? end, 1_000)
    refute_receive {:performed, _, _}, 100
  end

  defp eventually(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      if fun.(), do: true, else: Process.sleep(20) && false
    end)
    |> Enum.find(fn done -> done or System.monotonic_time(:millisecond) > deadline end)
  end

  # A CAPTURA NUNCA ACONTECEU NUMA CAÇADA, e o diário dele prova: no dia 10/09
  # inteiro, 84 "mira pronta" e ZERO varreduras, ZERO bolas comuns. O portão do
  # `scan_obs/1` exigia `player_mode == "still"` — herança de quando a captura
  # era só da pesca ("já funcionou um dia enquanto eu pescava"). Com a estrada
  # SEGURADA pelo cérebro o personagem está tão parado quanto no modo Parado, e
  # é esse o instante que o `{:capture_now}` marca.
  @tag :tmp_dir
  test "hunting with the road held, the ball goes out", %{worker: worker} do
    Settings.put(:player_mode, "hunt")
    :ok = Worker.mode_changed(worker)

    WorldState.put(:orders, %{route: :hold}, System.monotonic_time(:millisecond))
    list_empty()

    saw_standing(worker, [{130, 224}])
    world!(worker, corpses_obs([{130, 224}]))

    assert_receive {:performed, :high, acoes}, 1_000
    assert {:move, {130, 224}} in acoes
    assert {:press, Pokex.Settings.get(:ball_key)} in acoes

    # …e o cérebro fica sabendo que há bola na conta, pra segurar os pés.
    assert eventually(
             fn ->
               match?(
                 {:ok, %{pending: 1}},
                 WorldState.get(:capture, 5_000, System.monotonic_time(:millisecond))
               )
             end,
             1_000
           )
  end

  # AS BOLAS DE 10/09 NO TOOLBAR. As costas pretas do Shiny Golem ensinado casam
  # por cor com o toolbar cinza-escuro, e a varredura achou o corpo em cima dos
  # ícones do topo do cliente (y=32). O olho não viu bicho nenhum ali — e é essa
  # a prova que conta.
  @tag :tmp_dir
  test "hunting, a look-alike where no creature stood gets no ball", %{worker: worker} do
    Settings.put(:player_mode, "hunt")
    :ok = Worker.mode_changed(worker)

    WorldState.put(:orders, %{route: :hold}, System.monotonic_time(:millisecond))
    list_empty()

    saw_standing(worker, [{130, 224}])
    world!(worker, corpses_obs([{700, 32}, {130, 224}]))

    assert_receive {:performed, :high, acoes}, 1_000
    assert {:move, {130, 224}} in acoes
    refute {:move, {700, 32}} in acoes
  end

  @tag :tmp_dir
  test "hunting, with no creature ever seen standing, nothing is thrown", %{worker: worker} do
    Settings.put(:player_mode, "hunt")
    :ok = Worker.mode_changed(worker)

    WorldState.put(:orders, %{route: :hold}, System.monotonic_time(:millisecond))
    list_empty()

    world!(worker, corpses_obs([{130, 224}]))

    refute_receive {:performed, _p, _a}, 300
  end

  # 10/09, duas horas de caçada: 2.123 bolas, 1.353 com a pilha ainda chegando e
  # 272 no meio do combo — só 435 com a lista zerada. A estrada fica segurada a
  # luta inteira, então "parado" nunca quis dizer "a luta acabou".
  @tag :tmp_dir
  test "hunting with the road held but enemies still listed, nothing is thrown", %{
    worker: worker
  } do
    Settings.put(:player_mode, "hunt")
    :ok = Worker.mode_changed(worker)

    WorldState.put(:orders, %{route: :hold}, System.monotonic_time(:millisecond))
    WorldState.put(:situation, %{enemies: 5}, System.monotonic_time(:millisecond))

    saw_standing(worker, [{130, 224}])
    world!(worker, corpses_obs([{130, 224}]))

    refute_receive {:performed, _p, _a}, 300

    assert Worker.status(worker).hold_reason ==
             "bicho vivo na tela — a bola espera a lista zerar"
  end

  # O CÉREBRO DIZ QUE A LUTA ACABOU, NÃO O COMBAT. No Auto Combo o Combat fica
  # "lutando" enquanto a lista tiver a linha do pokémon dele; o cérebro desconta
  # essa linha e já está em 0. As 5 chamadas de 11/09 depois da meia-noite:
  # cérebro em 0, Combat "lutando como Shiny Venusaur", varredura fechada.
  @tag :tmp_dir
  test "hunting, Combat still 'fighting' but the brain sees a clean screen: the ball goes out",
       %{worker: worker} do
    Settings.put(:player_mode, "hunt")
    :ok = Worker.mode_changed(worker)
    send(worker, {:combat, %{state: :fighting, counters: %{}, error: nil, locked_row: 0}})

    WorldState.put(:orders, %{route: :hold}, System.monotonic_time(:millisecond))
    list_empty()

    saw_standing(worker, [{130, 224}])
    world!(worker, corpses_obs([{130, 224}]))

    assert_receive {:performed, :high, acoes}, 1_000
    assert {:move, {130, 224}} in acoes
    refute Worker.status(worker).hold_reason == "esperando fim da luta"
  end

  # O CÉREBRO SÓ SEGURA OS PÉS PRA OLHAR SE HÁ ALGUÉM PRA JOGAR: o worker diz
  # `armed?` no fato `:capture` ao armar, a cada segundo enquanto armado, e
  # desdiz ao parar.
  @tag :tmp_dir
  test "an armed worker says so on the :capture fact, and stops saying it when halted", %{
    worker: worker
  } do
    assert eventually(fn -> match?({:ok, %{armed?: true}}, capture_fact()) end, 1_000)

    :ok = Worker.halt(worker)
    assert eventually(fn -> match?({:ok, %{armed?: false}}, capture_fact()) end, 1_000)
  end

  defp capture_fact, do: WorldState.get(:capture, 5_000, System.monotonic_time(:millisecond))

  @tag :tmp_dir
  test "hunting with the road WALKING, nothing is thrown", %{worker: worker} do
    Settings.put(:player_mode, "hunt")
    :ok = Worker.mode_changed(worker)

    WorldState.put(:orders, %{route: :go}, System.monotonic_time(:millisecond))

    world!(worker, corpses_obs([{130, 224}]))

    refute_receive {:performed, _p, _a}, 300
  end

  # O painel dizia "capturando" a caçada inteira com todo portão fechado; depois
  # passou a dizer "na caçada só o shiny leva bola", que era verdade enquanto a
  # varredura exigia o modo Parado. Agora a caçada captura com a rota segurada,
  # e o que a tela deve dizer é o que FALTA: parar.
  @tag :tmp_dir
  test "walking, the status says what is missing: the road stopping" do
    worker = start_hunt_worker()

    assert %{hold_reason: "andando — a bola sai quando a rota parar"} = Worker.status(worker)

    stage_aim([])
    send(worker, {:shiny_seen, %{name: "Electrode shiny", px: 80, point: {116, 116}}})

    assert eventually(fn -> Worker.status(worker).state == :armed end, 1_000)
    assert Worker.status(worker).hold_reason == "mirando o corpo do shiny pela cor"
  end

  # SEGURAR NÃO É CEGAR: com bicho de pé a mira recusa a olhada, e isso não pode
  # aparecer no placar como varredura cega.
  @tag :tmp_dir
  test "a held aim does not count as a blind scan" do
    Settings.put(:player_mode, "hunt")
    SettingsStash.stash!(special_color_scan_ms: 50)
    {:ok, body} = FakeBody.start_link(self())

    aimer = fn -> %{scanning?: false, source: :shiny_aim, reason: {:alive_on_screen, 3}} end
    worker = start_supervised!({Worker, name: nil, body: body, aimer: aimer}, id: :held_worker)
    :ok = Worker.run(worker)

    send(worker, {:shiny_seen, %{name: "Electrode shiny", px: 80, point: {116, 116}}})
    assert eventually(fn -> Worker.status(worker).aim? end, 1_000)
    Process.sleep(200)

    assert Worker.status(worker).counters.blind == 0
    refute_receive {:performed, _, _}, 100
  end
end
