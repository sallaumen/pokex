defmodule Pokex.Bots.Fishing.LogicTest do
  use ExUnit.Case, async: true
  alias Pokex.Bots.Fishing.Logic

  def config do
    %{
      water_point: {800, 400},
      neutral_point: {860, 470},
      rod_key: "shift+v",
      tick_ms_watching: 200,
      tick_ms_default: 300,
      wait_focus_ms: 150,
      wait_after_equip_ms: 300,
      wait_cast_settle_ms: nil,
      wait_assess_ms: 1500,
      watch_timeout_ms: 30_000,
      watch_dead_streak_needed: 10,
      max_consecutive_failures: 3,
      glow_streak_needed: 1,
      calm_streak_needed: 1,
      dry_casts_alarm: 0
    }
  end

  def cursor_obs, do: %{cursor: {500, 500}}

  def advance_to(:focusing), do: elem(Logic.start(Logic.new(config()), 0), 0)

  def advance_to(:casting) do
    {l, _} = Logic.step(advance_to(:focusing), cursor_obs(), 200)
    l
  end

  def advance_to(:watching) do
    {l, _} = Logic.step(advance_to(:casting), cursor_obs(), 600)
    l
  end

  describe "arremessos secos (a testemunha do cast)" do
    # Uma tecla de vara engolida (portão, foco, helper caído) devolve :ok e a
    # água simplesmente nunca borbulha. A tela é a única testemunha de que o
    # cast aconteceu — N ciclos SEM NENHUMA bolha tocam o alarme.
    defp dry_config, do: Map.put(config(), :dry_casts_alarm, 3)

    # um ciclo inteiro: assenta, nunca vê bolha, estoura o watch_timeout → recast
    defp dry_cycle({logic, _actions}, base) do
      {logic, _} = Logic.step(logic, %{glow: false, line?: false}, base)
      Logic.step(logic, %{glow: false, line?: false}, base + logic.config.watch_timeout_ms + 1)
    end

    test "3 ciclos sem NENHUMA bolha tocam o alarme no 3º recast — e recomeçam" do
      {l, _} =
        Logic.step(advance_to(:focusing) |> Map.put(:config, dry_config()), cursor_obs(), 200)

      first_cast = Logic.step(l, cursor_obs(), 600)

      # o PRIMEIRO cast nunca alarma (não herda secura de ciclo que não existiu)
      {_l, actions} = first_cast
      refute Enum.any?(actions, &match?({:alarm, _}, &1))

      # secos 1 e 2: recasts sem alarme
      {l, actions} = dry_cycle(first_cast, 1_000)
      refute Enum.any?(actions, &match?({:alarm, _}, &1))
      assert l.dry_casts == 1

      {l, actions} = dry_cycle({l, []}, 40_000)
      refute Enum.any?(actions, &match?({:alarm, _}, &1))
      assert l.dry_casts == 2

      # seco 3: ALARME no recast, e a contagem recomeça (re-alarma se seguir seco)
      {l, actions} = dry_cycle({l, []}, 80_000)
      assert Enum.any?(actions, &match?({:alarm, "🎣 3 arremessos" <> _}, &1))
      assert l.dry_casts == 0
    end

    test "UMA bolha vista zera a secura acumulada" do
      {l, _} =
        Logic.step(advance_to(:focusing) |> Map.put(:config, dry_config()), cursor_obs(), 200)

      cast = Logic.step(l, cursor_obs(), 600)

      {l, _} = dry_cycle(cast, 1_000)
      {l, _} = dry_cycle({l, []}, 40_000)
      assert l.dry_casts == 2

      # o ciclo seguinte VÊ uma bolha (assentado + glow) antes de estourar
      {l, _} = Logic.step(l, %{glow: false, line?: false}, 80_000)
      {l, _} = Logic.step(l, %{glow: true, line?: false}, 80_100)
      assert l.glow_seen?

      # o próximo recast não é seco: houve bolha no ciclo → a contagem ZERA
      {l, actions} =
        Logic.step(l, %{glow: false, line?: false}, 80_000 + l.config.watch_timeout_ms + 200)

      refute Enum.any?(actions, &match?({:alarm, _}, &1))
      assert l.dry_casts == 0
    end

    test "com dry_casts_alarm 0 (desligado) nunca alarma, por mais seco que fique" do
      {l, _} = Logic.step(advance_to(:focusing), cursor_obs(), 200)
      cast = Logic.step(l, cursor_obs(), 600)

      {_l, actions} =
        Enum.reduce(1..6, cast, fn i, acc ->
          {l, actions} = dry_cycle(acc, i * 40_000)
          refute Enum.any?(actions, &match?({:alarm, _}, &1))
          {l, actions}
        end)

      refute Enum.any?(actions, &match?({:alarm, _}, &1))
    end
  end

  test "start only from idle or error" do
    {l, []} = Logic.start(Logic.new(config()), 0)
    assert l.state == :focusing
    # começar de novo não muda nada
    assert {^l, []} = Logic.start(l, 10)
  end

  test "focusing over a LIVE line skips the recast and watches it (the Focus resume)" do
    # Clicking another window pauses the bot (Focus); coming back restarts the
    # fishing logic — but the previous cast may still be IN the water (the
    # resting line's ring pulses continuously, so line? is readable on the very
    # first frame). Recasting would reset the whole cycle and lose the live
    # bait (Lucas, 2026-07-20): with the line present, skip focusing/casting
    # and watch it — settled (the splash is long gone) and with no actions.
    {l, actions} = Logic.step(advance_to(:focusing), %{cursor: {500, 500}, line?: true}, 0)

    assert l.state == :watching
    assert l.settled? == true
    # no click, no move, no rod press — nothing to disturb the live line
    assert [{:log, log}] = actions
    assert log =~ "isca já na água"
    # no cast happened: the cycle counter must not tick
    assert l.counters.cycles == 0
  end

  test "focusing WITHOUT a live line follows the normal click-and-cast path" do
    {l, actions} = Logic.step(advance_to(:focusing), %{cursor: {500, 500}, line?: false}, 0)
    assert l.state == :casting
    assert actions == [{:click, :left, {860, 470}}]
  end

  test "focusing clicks neutral point and waits" do
    {l, actions} = Logic.step(advance_to(:focusing), cursor_obs(), 0)
    assert l.state == :casting
    assert actions == [{:click, :left, {860, 470}}]
    assert l.waiting_until == 150
    # tick dentro da espera: nada acontece
    assert {^l, []} = Logic.step(l, cursor_obs(), 100)
  end

  test "casting positions the cursor and Quick-Casts the rod in ONE atomic sequence (move, wait, press)" do
    {l, actions} = Logic.step(advance_to(:casting), cursor_obs(), 400)
    assert l.state == :watching
    # move to water → settle wait → press the rod (Quick Cast throws at the cursor, no click),
    # one perform, so no combat action can move the cursor between positioning and casting
    assert actions == [
             {:move, {800, 400}},
             {:wait, 300},
             {:press, "shift+v"}
           ]

    assert l.counters.cycles == 1
  end

  test "casting arms a settle window; a bubble during it isn't a bite yet" do
    cfg = Map.put(config(), :wait_cast_settle_ms, 500)
    {watching, _} = Logic.step(%{advance_to(:casting) | config: cfg}, cursor_obs(), 400)
    assert watching.state == :watching
    assert watching.waiting_until == 400 + 500
    # a glow inside the settle window is a no-op (still waiting out the splash)
    assert {^watching, []} = Logic.step(watching, Map.put(cursor_obs(), :glow, true), 800)
  end

  test "watching: settle on calm water first, THEN a bubble hooks and loops back to casting" do
    watching = advance_to(:watching)
    refute watching.settled?

    # cyan BEFORE settling = the cast splash → ignored, stays watching
    {still, []} = Logic.step(watching, Map.put(cursor_obs(), :glow, true), 650)
    assert still.state == :watching
    refute still.settled?

    # calm water → settled (splash gone)
    {settled, []} = Logic.step(watching, Map.put(cursor_obs(), :glow, false), 700)
    assert settled.state == :watching
    assert settled.settled?

    # now a bubble is a real bite → hook, and loop straight back to casting (no combat)
    {l, actions} = Logic.step(settled, Map.put(cursor_obs(), :glow, true), 900)
    assert l.state == :casting
    assert actions == [{:press, "shift+v"}]
    assert l.counters.hooked == 1
    assert l.waiting_until == 900 + 1500
  end

  test "a confirmed bite hooks and loops straight back to casting (no combat)" do
    settled = %Logic{state: :watching, settled?: true, config: config()}
    {l, actions} = Logic.step(settled, Map.put(cursor_obs(), :glow, true), 1000)
    assert l.state == :casting
    assert actions == [{:press, "shift+v"}]
    assert l.counters.hooked == 1
  end

  test "watching debounces the bite: needs consecutive bubble frames to hook" do
    cfg = Map.put(config(), :glow_streak_needed, 2)
    watching = %Logic{state: :watching, config: cfg, entered_at: 0, settled?: true}

    {l, actions} = Logic.step(watching, Map.put(cursor_obs(), :glow, true), 100)
    assert l.state == :watching
    assert actions == []
    assert l.glow_streak == 1

    {l, actions} = Logic.step(l, Map.put(cursor_obs(), :glow, true), 200)
    assert l.state == :casting
    assert actions == [{:press, "shift+v"}]

    # a lone bubble frame followed by calm resets the streak
    {reset, _} = Logic.step(watching, Map.put(cursor_obs(), :glow, true), 100)
    {reset, _} = Logic.step(reset, Map.put(cursor_obs(), :glow, false), 200)
    assert reset.glow_streak == 0
  end

  test "watching: an oscillating cast splash never latches settled? and never hooks" do
    cfg = config() |> Map.put(:calm_streak_needed, 2) |> Map.put(:glow_streak_needed, 2)

    watching = %Logic{
      state: :watching,
      config: cfg,
      entered_at: 0,
      settled?: false,
      calm_streak: 0,
      glow_streak: 0
    }

    # splash oscillates crest/trough; each trough advances calm_streak to 1,
    # each crest resets it to 0 → settled? can never reach the 2-consecutive gate.
    seq = [true, false, true, false, true, true]

    {final, _acts} =
      Enum.reduce(Enum.with_index(seq), {watching, []}, fn {glow, i}, {l, _} ->
        Logic.step(l, Map.put(cursor_obs(), :glow, glow), 100 + i * 100)
      end)

    assert final.state == :watching
    refute final.settled?
  end

  test "watching: settles only after calm_streak_needed consecutive calm frames" do
    cfg = Map.put(config(), :calm_streak_needed, 2)

    watching = %Logic{
      state: :watching,
      config: cfg,
      entered_at: 0,
      settled?: false,
      calm_streak: 0
    }

    {one, []} = Logic.step(watching, Map.put(cursor_obs(), :glow, false), 100)
    refute one.settled?
    assert one.calm_streak == 1

    {two, []} = Logic.step(one, Map.put(cursor_obs(), :glow, false), 200)
    assert two.settled?
  end

  test "watching: a splash crest resets the calm run before settling" do
    cfg = Map.put(config(), :calm_streak_needed, 2)

    watching = %Logic{
      state: :watching,
      config: cfg,
      entered_at: 0,
      settled?: false,
      calm_streak: 0
    }

    {one, []} = Logic.step(watching, Map.put(cursor_obs(), :glow, false), 100)
    assert one.calm_streak == 1

    {crest, []} = Logic.step(one, Map.put(cursor_obs(), :glow, true), 200)
    refute crest.settled?
    assert crest.calm_streak == 0
  end

  test "watching: after settling, a bubble still hooks even much later" do
    cfg = config() |> Map.put(:calm_streak_needed, 2) |> Map.put(:glow_streak_needed, 1)

    watching = %Logic{
      state: :watching,
      config: cfg,
      entered_at: 0,
      settled?: false,
      calm_streak: 0
    }

    {a, []} = Logic.step(watching, Map.put(cursor_obs(), :glow, false), 100)
    {settled, []} = Logic.step(a, Map.put(cursor_obs(), :glow, false), 200)
    assert settled.settled?

    # a calm dip mid-watch keeps settled? true (clause c)
    {still, []} = Logic.step(settled, Map.put(cursor_obs(), :glow, false), 15_000)
    assert still.settled?

    {hooked, [{:press, "shift+v"}]} =
      Logic.step(still, Map.put(cursor_obs(), :glow, true), 15_100)

    assert hooked.state == :casting
  end

  test "watching recasts immediately after the absolute watch timeout" do
    # a single frame past watch_timeout_ms trips the backstop even before the
    # dead-frame streak fills; recovery re-arms + re-throws immediately.
    watching = advance_to(:watching)
    {l, actions} = Logic.step(watching, Map.put(cursor_obs(), :glow, false), 600 + 30_001)
    assert l.state == :watching
    assert [{:log, _}, {:move, _}, {:wait, _}, {:press, "shift+v"}] = actions
  end

  test "watching recasts immediately after watch_dead_streak_needed no-bubble frames" do
    # config() sets watch_dead_streak_needed: 10; feed 10 consecutive no-bite
    # frames with the clock well under watch_timeout_ms so ONLY the dead-frame
    # path can fire. Recovery re-arms the rod (press shift+v) in the same step.
    watching = advance_to(:watching)

    {result, actions} =
      Enum.reduce(1..10, {watching, []}, fn i, {l, _} ->
        Logic.step(l, Map.put(cursor_obs(), :glow, false), 700 + i * 100)
      end)

    assert result.state == :watching
    assert [{:log, msg}, {:move, _}, {:wait, _}, {:press, "shift+v"}] = actions
    assert msg =~ "re-lançando"
  end

  test "a bubble frame resets the dead-frame streak — a live line is never recast mid-bite" do
    # already settled and part-way to the dead threshold; a bite-magnitude frame
    # (needs 2 to hook here) doesn't hook yet but must clear the dead streak, so a
    # slow-but-live bite can never trip the recast.
    cfg = Map.put(config(), :glow_streak_needed, 2)

    watching = %Logic{
      state: :watching,
      config: cfg,
      entered_at: 0,
      settled?: true,
      dead_streak: 9
    }

    {live, []} = Logic.step(watching, Map.put(cursor_obs(), :glow, true), 100)
    assert live.state == :watching
    assert live.dead_streak == 0
    assert live.glow_streak == 1
  end

  test "a present line pulsing below the bite threshold holds the dead streak (only empty water counts)" do
    # line? true = the cast line is in the water (pulsing between bites) but below
    # the bite threshold → NOT a dead frame: a resting line keeps fishing forever.
    watching = %Logic{
      state: :watching,
      config: config(),
      entered_at: 0,
      settled?: true,
      dead_streak: 7
    }

    {held, []} = Logic.step(watching, %{cursor: {500, 500}, glow: false, line?: true}, 100)
    assert held.state == :watching
    assert held.dead_streak == 0

    # line? false = near-empty water (dropped rod) → this one DOES count up
    {climb, []} = Logic.step(held, %{cursor: {500, 500}, glow: false, line?: false}, 200)
    assert climb.dead_streak == 1
  end

  test "kill corner stops from any active state" do
    {l, actions} = Logic.step(advance_to(:watching), %{cursor: {5, 5}, glow: true}, 700)
    assert l.state == :idle
    assert [{:log, _}] = actions
  end

  test "needs per state" do
    # :glow so the very first frame can already see a live line (skip-recast)
    assert Logic.needs(advance_to(:focusing)) == [:cursor, :glow]
    # gate off (default) → no skill-bar read
    assert Logic.needs(advance_to(:watching)) == [:cursor, :glow]
    assert Logic.needs(%Logic{state: :idle}) == []
  end

  test "watching asks for the cooldown reading only when the gate is on" do
    gate_on = %Logic{state: :watching, config: Map.put(config(), :require_cooldowns, true)}
    assert Logic.needs(gate_on) == [:cursor, :glow, :cooldowns_ready?]
  end

  describe "cooldown gate (require_cooldowns)" do
    defp settled(require_cooldowns) do
      cfg = Map.put(config(), :require_cooldowns, require_cooldowns)
      %Logic{state: :watching, settled?: true, config: cfg}
    end

    defp bite(ready?),
      do: cursor_obs() |> Map.put(:glow, true) |> Map.put(:cooldowns_ready?, ready?)

    # a below-threshold trough between bite peaks: glow false, line still present
    defp trough, do: cursor_obs() |> Map.put(:glow, false) |> Map.put(:line?, true)

    test "gate OFF: hooks normally even when the skills aren't ready" do
      {l, actions} = Logic.step(settled(false), bite(false), 1000)
      assert actions == [{:press, "shift+v"}]
      assert l.counters.hooked == 1
    end

    test "gate ON + skills not ready: HOLDS the fish (no rod press, no hook)" do
      {l, actions} = Logic.step(settled(true), bite(false), 1000)

      assert l.state == :watching
      assert l.counters.hooked == 0
      assert l.holding?
      refute Enum.any?(actions, &match?({:press, _}, &1))
      assert actions == [{:log, "🔒 fisga segurada — skills em cooldown"}]
    end

    test "gate ON + skills ready: hooks" do
      {l, actions} = Logic.step(settled(true), bite(true), 1000)
      assert actions == [{:press, "shift+v"}]
      assert l.counters.hooked == 1
      refute l.holding?
    end

    test "the hold is announced once, then stays silent while held" do
      {held1, a1} = Logic.step(settled(true), bite(false), 1000)
      assert a1 == [{:log, "🔒 fisga segurada — skills em cooldown"}]

      {held2, a2} = Logic.step(held1, bite(false), 1100)
      assert a2 == []
      assert held2.holding?
    end

    test "a held fish is pulled the instant the skills come ready" do
      {held, _} = Logic.step(settled(true), bite(false), 1000)
      {l, actions} = Logic.step(held, bite(true), 1100)
      assert actions == [{:press, "shift+v"}]
      assert l.counters.hooked == 1
      refute l.holding?
    end

    test "pokemon gate: pokemon_ok? false HOLDS with the worker's reason in the feed" do
      obs =
        cursor_obs()
        |> Map.put(:glow, true)
        |> Map.merge(%{pokemon_ok?: false, pokemon_hold_reason: "vida 22% < 40%"})

      {l, actions} = Logic.step(settled(false), obs, 1000)

      assert l.state == :watching
      assert l.counters.hooked == 0
      assert l.holding?
      assert actions == [{:log, "🔒 fisga segurada — vida 22% < 40%"}]
    end

    test "pokemon gate: absent key (gate off / fact unknown) hooks normally" do
      obs = cursor_obs() |> Map.put(:glow, true)
      {l, actions} = Logic.step(settled(false), obs, 1000)
      assert actions == [{:press, "shift+v"}]
      assert l.counters.hooked == 1
    end

    test "pokemon gate: a held fish is pulled the instant the pokemon recovers" do
      low =
        cursor_obs()
        |> Map.put(:glow, true)
        |> Map.merge(%{pokemon_ok?: false, pokemon_hold_reason: "sem pokémon ativo"})

      {held, a1} = Logic.step(settled(false), low, 1000)
      assert held.holding?
      assert a1 == [{:log, "🔒 fisga segurada — sem pokémon ativo"}]

      ok = cursor_obs() |> Map.put(:glow, true) |> Map.put(:pokemon_ok?, true)
      {l, actions} = Logic.step(held, ok, 1100)
      assert actions == [{:press, "shift+v"}]
      assert l.counters.hooked == 1
      refute l.holding?
    end

    test "both gates closed: ONE hold, both reasons announced" do
      obs =
        bite(false)
        |> Map.merge(%{pokemon_ok?: false, pokemon_hold_reason: "sem pokémon ativo"})

      {l, actions} = Logic.step(settled(true), obs, 1000)

      assert l.holding?
      assert actions == [{:log, "🔒 fisga segurada — skills em cooldown + sem pokémon ativo"}]
    end

    test "the hold exposes its reason on the struct (panel snapshot), cleared on the pull" do
      obs =
        bite(false)
        |> Map.merge(%{pokemon_ok?: false, pokemon_hold_reason: "sem pokémon ativo"})

      {held, _} = Logic.step(settled(true), obs, 1000)
      assert held.hold_reason == "skills em cooldown + sem pokémon ativo"

      pull = bite(true) |> Map.put(:pokemon_ok?, true)
      {pulled, _} = Logic.step(held, pull, 1100)
      assert pulled.hold_reason == nil
      assert pulled.last_action == %{text: "fisgada", at: 1100}
    end

    test "a cast records the last action (panel snapshot)" do
      {l, _actions} = Logic.step(advance_to(:casting), cursor_obs(), 600)
      assert l.state == :watching
      assert l.last_action == %{text: "arremesso da isca", at: 600}
    end

    test "gate ON + UNKNOWN reading (nil): holds — a capture glitch must not pull the fish" do
      {l, actions} = Logic.step(settled(true), bite(nil), 1000)

      assert l.state == :watching
      assert l.counters.hooked == 0
      assert l.holding?
      refute Enum.any?(actions, &match?({:press, _}, &1))
    end

    test "the hold ceiling (hook_hold_max_ms) pulls anyway, loudly" do
      cfg =
        config()
        |> Map.put(:require_cooldowns, true)
        |> Map.put(:hook_hold_max_ms, 5_000)

      w = %Logic{state: :watching, settled?: true, config: cfg}

      {w, _} = Logic.step(w, bite(false), 1_000)
      assert w.holding? and w.holding_since == 1_000

      # peaks keep refreshing entered_at but NOT holding_since — the ceiling measures
      # the whole hold, not time-since-last-peak
      {w, _} = Logic.step(w, bite(false), 4_000)
      assert w.holding_since == 1_000

      {w, actions} = Logic.step(w, bite(false), 6_100)
      assert {:press, "shift+v"} in actions
      assert Enum.any?(actions, &match?({:log, "⏳" <> _}, &1))
      assert w.counters.hooked == 1
      refute w.holding?
      assert w.holding_since == nil
    end

    test "a held bite survives oscillation troughs — no re-log, no recast" do
      cfg = config() |> Map.put(:require_cooldowns, true) |> Map.put(:watch_timeout_ms, 100)
      w = %Logic{state: :watching, settled?: true, config: cfg, entered_at: 0}

      {w, a1} = Logic.step(w, bite(false), 1000)
      assert w.holding? and w.entered_at == 1000
      assert a1 == [{:log, "🔒 fisga segurada — skills em cooldown"}]

      # a below-threshold trough: keeps holding, no recast, and NO repeated log
      {w, a2} = Logic.step(w, trough(), 1050)
      assert w.state == :watching and w.holding?
      assert a2 == []

      # the next peak: still holding → silent, entered_at refreshed
      {w, a3} = Logic.step(w, bite(false), 1100)
      assert w.holding? and w.entered_at == 1100
      assert a3 == []
    end

    test "a held bite is NOT abandoned by the watch timeout (entered_at refreshes on peaks)" do
      cfg = config() |> Map.put(:require_cooldowns, true) |> Map.put(:watch_timeout_ms, 100)
      w = %Logic{state: :watching, settled?: true, config: cfg, entered_at: 0}

      {w, _} = Logic.step(w, bite(false), 1000)
      # a peak 90ms later refreshes entered_at → 1090 (still holding)
      {w, _} = Logic.step(w, bite(false), 1090)
      # a trough 90ms after THAT peak is within the 100ms window → not timed out
      # (with the old time-since-cast timeout this would have recast at ~1100)
      {w, actions} = Logic.step(w, trough(), 1180)
      assert w.state == :watching
      assert actions == []
    end
  end

  test "tick_interval per state" do
    assert Logic.tick_interval(advance_to(:watching)) == 200
    assert Logic.tick_interval(advance_to(:focusing)) == 300
  end

  test "io_failed counts and eventually errors" do
    l = advance_to(:watching)
    {l, _} = Logic.io_failed(l, "boom", 700)
    assert l.state == :casting
    assert l.failures == 1
    assert l.counters.failures == 1

    {l, _} = Logic.io_failed(l, "boom", 800)
    {l, _} = Logic.io_failed(l, "boom", 900)
    assert l.state == :error
    assert l.error =~ "boom"
  end

  test "kill corner beats an active waiting_until" do
    # focusing sets waiting_until = now + wait_focus_ms (150); stepping again at
    # now < 150 would normally be a no-op wait — kill corner must still win.
    focusing = advance_to(:focusing)
    {casting, _} = Logic.step(focusing, cursor_obs(), 0)
    assert casting.state == :casting
    assert casting.waiting_until == 150

    {killed, actions} = Logic.step(casting, %{cursor: {3, 3}}, 50)
    assert killed.state == :idle
    assert [{:log, _}] = actions
  end
end
