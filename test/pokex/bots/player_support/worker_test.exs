defmodule Pokex.Bots.PlayerSupport.WorkerTest.FakeBody do
  @moduledoc "Records Body.perform calls and forwards them to the test process."
  use GenServer

  def start_link(test), do: GenServer.start_link(__MODULE__, test)

  @impl true
  def init(test), do: {:ok, test}

  @impl true
  def handle_call({:perform, actions, priority, _requested_at}, _from, test) do
    send(test, {:performed, priority, actions})
    {:reply, :ok, test}
  end
end

defmodule Pokex.Bots.PlayerSupport.WorkerTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.PlayerSupport.Worker
  alias Pokex.Bots.PlayerSupport.WorkerTest.FakeBody
  alias Pokex.{Calibration, Settings, SettingsStash}

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    # the combo ships OFF by default; the enabled-path tests turn it on ("toggle off" flips it
    # back). potion_battle_clear_ms: 0 keeps the pre-window tests meaningful (one clear read
    # fires) — the window tests set their own value.
    SettingsStash.stash!(
      support_tick_ms: 20,
      rescue_step_ms: 0,
      rescue_enabled: true,
      potion_battle_clear_ms: 0
    )

    SettingsStash.stash_keys!([
      :rescue_cooldown_ms,
      :rescue_mode,
      :rescue_combo,
      :pokemon_hp_rescue_pct,
      :potion_enabled,
      :potion_cooldown_ms,
      :pokemon_hp_potion_pct,
      :reposition_enabled,
      :reposition_battle_clear_ms,
      :player_mode,
      :support_waits_capture,
      :support_capture_wait_max_ms,
      :escape_direction,
      :escape_steps,
      :escape_walk_wait_ms,
      :calibration_front_delay_ms
    ])

    on_exit(fn -> Pokex.Perception.WorldState.forget(:pokemon) end)

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: 1000,
      screen_h: 700,
      water_point: {400, 300},
      glow_region: {0, 0, 20, 20},
      battle_region: {0, 0, 20, 20},
      arena_region: {0, 0, 200, 200},
      neutral_point: {500, 500},
      pokemon_hp_region: {0, 0, 20, 4},
      pokemon_photo_point: {40, 620}
    })

    {:ok, body} = FakeBody.start_link(self())
    %{tmp: tmp, body: body}
  end

  # An HP bar PNG: `fill_cols` green columns then dark to `total`.
  defp hp_png(dir, name, fill_cols, total \\ 20) do
    rows =
      for _y <- 1..4 do
        for x <- 1..total, do: if(x <= fill_cols, do: {40, 200, 60, 255}, else: {17, 17, 17, 255})
      end

    Pokex.PngFixtures.write!(Path.join(dir, name), rows)
  end

  defp start_worker(body), do: start_supervised!({Worker, name: nil, body: body})

  # A battle-body PNG big enough to cover every lock band: all dark-red = a locked fight,
  # all dark = no fight. 100 wide × 400 tall so each 52px band holds thousands of pixels.
  defp battle_png(dir, name, color) do
    rows = for _y <- 1..400, do: List.duplicate(color, 100)
    Pokex.PngFixtures.write!(Path.join(dir, name), rows)
  end

  @tag :tmp_dir
  test "holds (no combo) while the HP bar is full", %{tmp: tmp, body: body} do
    full = hp_png(tmp, "full.png", 20)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, full}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    refute_receive {:performed, _priority, _actions}, 200
    assert Worker.status(worker).hp_pct == 100
  end

  # The old reader turned bright game-world pixels into a garbage low-HP % and fired the
  # combo in a loop.
  @tag :tmp_dir
  test "a MINIMIZED party window (region shows game world) reads UNKNOWN and never acts", %{
    tmp: tmp,
    body: body
  } do
    Settings.put(:rescue_enabled, true)
    Settings.put(:potion_enabled, true)

    rows = for _y <- 1..4, do: List.duplicate({120, 180, 235, 255}, 20)
    world = Pokex.PngFixtures.write!(Path.join(tmp, "world.png"), rows)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, world}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    refute_receive {:performed, _priority, _actions}, 300
    status = Worker.status(worker)
    assert status.hp_pct == nil
    assert status.error =~ "não reconhecida"
    assert status.counters.rescues == 0
    assert status.counters.potions == 0
  end

  @tag :tmp_dir
  test "halt STICKS (panic path): no reads or actions after halt, run re-arms", %{
    tmp: tmp,
    body: body
  } do
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, low}]})
    Settings.put(:rescue_cooldown_ms, 1)

    worker = start_worker(body)
    assert :ok = Worker.run(worker)
    assert_receive {:performed, :critical, _}, 1_000
    assert Worker.status(worker).state == :monitoring

    assert :ok = Worker.halt(worker)
    assert Worker.status(worker).state == :idle
    reads_at_halt = Worker.status(worker).counters.reads
    refute_receive {:performed, _priority, _actions}, 300
    assert Worker.status(worker).counters.reads == reads_at_halt

    assert :ok = Worker.run(worker)
    assert Worker.status(worker).state == :monitoring
    assert_receive {:performed, :critical, _}, 1_000
  end

  # A real full bar reads raw 95: the rounded tip never paints the last columns of the box.
  @tag :tmp_dir
  test "the rounded bar tip is corrected: raw 95% reads as a genuinely FULL 100%", %{
    tmp: tmp,
    body: body
  } do
    nearly = hp_png(tmp, "nearly.png", 19)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, nearly}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    refute_receive {:performed, _priority, _actions}, 200
    assert Worker.status(worker).hp_pct == 100
  end

  @tag :tmp_dir
  test "fires the survival combo at :critical when HP is below the threshold", %{
    tmp: tmp,
    body: body
  } do
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, low}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    assert_receive {:performed, :critical, actions}, 1_000
    assert [{:press, "q"} | _] = actions
    assert {:move, {40, 620}} in actions
    assert {:press, "shift+q"} in actions
    assert {:move, {500, 500}} in actions

    assert Worker.status(worker).counters.rescues >= 1
  end

  @tag :tmp_dir
  test "combo mode: the stun comes before the recall, in the same :critical sequence", %{
    tmp: tmp,
    body: body
  } do
    Pokex.Combos.Store.put([
      %Pokex.Combos.Combo{
        name: "stun-do-resgate",
        trigger: nil,
        steps: [{:skill, "1"}, {:wait, 5}, {:skill, "2"}],
        enabled?: true
      }
    ])

    Settings.put(:rescue_mode, "combo")
    Settings.put(:rescue_combo, "stun-do-resgate")

    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, low}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    assert_receive {:performed, :critical, actions}, 1_000
    assert [{:press, "1"}, {:wait, 5}, {:press, "2"}, {:wait, 0}, {:press, "q"} | _] = actions
    assert {:press, "shift+q"} in actions
    assert {:move, {40, 620}} in actions
  end

  @tag :tmp_dir
  test "a dangling combo name still revives DIRECTLY, with an alarm saying why", %{
    tmp: tmp,
    body: body
  } do
    Phoenix.PubSub.subscribe(Pokex.PubSub, "game")
    Settings.put(:rescue_mode, "combo")
    Settings.put(:rescue_combo, "sumiu")

    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, low}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    assert_receive {:performed, :critical, [{:press, "q"} | _]}, 1_000
    assert_receive {:rule_alarm, msg}, 1_000
    assert msg =~ "sumiu"
    assert msg =~ "revivendo direto"
  end

  @tag :tmp_dir
  test "a single low-HP glitch frame between full reads never fires the combo", %{
    tmp: tmp,
    body: body
  } do
    full = hp_png(tmp, "full.png", 20)
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, full}, {:ok, low}, {:ok, full}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    refute_receive {:performed, _priority, _actions}, 400
    assert Worker.status(worker).counters.rescues == 0
  end

  @tag :tmp_dir
  test "the cooldown blocks a second combo within the window", %{tmp: tmp, body: body} do
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, low}]})
    Settings.put(:rescue_cooldown_ms, 60_000)

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    assert_receive {:performed, :critical, _}, 1_000
    refute_receive {:performed, :critical, _}, 300
    assert Worker.status(worker).counters.rescues == 1
  end

  @tag :tmp_dir
  test "publishes the :pokemon fact — HP when readable, readable?: false when not", %{
    tmp: tmp,
    body: body
  } do
    full = hp_png(tmp, "full.png", 20)
    rows = for _y <- 1..4, do: List.duplicate({120, 180, 235, 255}, 20)
    world = Pokex.PngFixtures.write!(Path.join(tmp, "world.png"), rows)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, full}, {:ok, world}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    assert wait_until(fn ->
             Pokex.Perception.pokemon() == {:ok, %{hp_pct: 100, readable?: true}}
           end)

    assert wait_until(fn ->
             Pokex.Perception.pokemon() == {:ok, %{hp_pct: nil, readable?: false}}
           end)
  end

  defp wait_until(fun, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 1_500

    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(20) && wait_until(fun, deadline)
    end
  end

  # The potion gate reads the :battle blackboard entry first, so each test pins WorldState:
  # a stale entry forces the direct capture+interpret fallback; a fresh one is read as-is.
  defp stale_battle! do
    at = System.monotonic_time(:millisecond) - 60_000
    Pokex.Perception.WorldState.put(:battle, %{enemies: [], locked?: false, captured_at: at}, at)
  end

  defp fresh_battle!(fields) do
    at = System.monotonic_time(:millisecond)

    obs =
      Enum.into(fields, %{enemies: [], red: [], locked?: false, locked_row: nil, captured_at: at})

    Pokex.Perception.WorldState.put(:battle, obs, at)
  end

  # During the minigame the Body is locked anyway, and the 120ms HP reads only queued
  # ahead of the game's strip capture (measured: 80ms cadence degraded to ~250ms).
  @tag :tmp_dir
  test "does not read HP while a minigame is in play — frees the broker for the strip", %{
    tmp: tmp,
    body: body
  } do
    Settings.put(:rescue_enabled, true)

    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, low}]})

    Pokex.Perception.WorldState.put(
      :mini_game,
      %{playing?: true, confidence: 0.9},
      System.monotonic_time(:millisecond)
    )

    on_exit(fn -> Pokex.Perception.WorldState.forget(:mini_game) end)

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    refute_receive {:performed, _priority, _actions}, 250
    assert Worker.status(worker).counters.reads == 0
    assert Worker.status(worker).hold_reason =~ "minigame"
  end

  @tag :tmp_dir
  test "sips a potion when HP is below the potion threshold and no fight is engaged", %{
    tmp: tmp,
    body: body
  } do
    Settings.put(:rescue_enabled, false)
    Settings.put(:potion_enabled, true)
    Settings.put(:potion_cooldown_ms, 60_000)

    stale_battle!()
    low = hp_png(tmp, "low.png", 6)
    no_fight = battle_png(tmp, "calm.png", {17, 17, 17, 255})
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, low}, {:ok, no_fight}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    assert_receive {:performed, :high, [{:press, "e"}]}, 1_000
    assert Worker.status(worker).counters.potions >= 1
  end

  @tag :tmp_dir
  test "the potion waits out a CONTINUOUS battle-free window before firing", %{
    tmp: tmp,
    body: body
  } do
    Settings.put(:rescue_enabled, false)
    Settings.put(:potion_enabled, true)
    Settings.put(:potion_cooldown_ms, 60_000)
    Settings.put(:potion_battle_clear_ms, 300)

    fresh_battle!(enemies: [])
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, low}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    refute_receive {:performed, :high, _}, 200
    assert Worker.status(worker).hold_reason == "poção esperando batalha limpa"
    assert_receive {:performed, :high, [{:press, "e"}]}, 1_000
    assert Worker.status(worker).counters.potions == 1
    assert %{text: "poção", at: _} = Worker.status(worker).last_action
  end

  @tag :tmp_dir
  test "post-fight order: a due potion waits for capture to resolve the corpses", %{
    tmp: tmp,
    body: body
  } do
    Settings.put(:rescue_enabled, false)
    Settings.put(:potion_enabled, true)
    Settings.put(:potion_cooldown_ms, 60_000)
    Settings.put(:support_waits_capture, true)

    fresh_battle!(enemies: [])
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, low}]})

    worker = start_worker(body)
    send(worker, {:catcher, %{pending_corpses: 1}})
    assert :ok = Worker.run(worker)

    refute_receive {:performed, :high, _}, 300
    assert Worker.status(worker).hold_reason =~ "esperando a captura terminar"

    send(worker, {:catcher, %{pending_corpses: 0}})
    assert_receive {:performed, :high, [{:press, "e"}]}, 1_000
  end

  @tag :tmp_dir
  test "the cap frees the support if capture wedges (fail-open)", %{tmp: tmp, body: body} do
    Settings.put(:rescue_enabled, false)
    Settings.put(:potion_enabled, true)
    Settings.put(:potion_cooldown_ms, 60_000)
    Settings.put(:support_waits_capture, true)
    Settings.put(:support_capture_wait_max_ms, 150)

    fresh_battle!(enemies: [])
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, low}]})

    worker = start_worker(body)
    send(worker, {:catcher, %{pending_corpses: 1}})
    assert :ok = Worker.run(worker)

    assert_receive {:performed, :high, [{:press, "e"}]}, 2_000
  end

  @tag :tmp_dir
  test "a LOCKED fight mid-window RESETS the clear clock", %{tmp: tmp, body: body} do
    Settings.put(:rescue_enabled, false)
    Settings.put(:potion_enabled, true)
    Settings.put(:potion_cooldown_ms, 60_000)
    Settings.put(:potion_battle_clear_ms, 400)

    fresh_battle!(enemies: [])
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, low}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    Process.sleep(200)
    fresh_battle!(enemies: [0], locked?: true, locked_row: 0)
    Process.sleep(100)
    fresh_battle!(enemies: [0], locked?: false)

    refute_receive {:performed, :high, _}, 250
    assert_receive {:performed, :high, [{:press, "e"}]}, 1_000
  end

  # The reported bug: potion configured and on, HP low, but a creature sat in the Battle
  # list (the normal state of hunting) and the sip never came.
  @tag :tmp_dir
  test "sips while HUNTING: an enemy merely listed no longer blocks the potion", %{
    tmp: tmp,
    body: body
  } do
    Settings.put(:rescue_enabled, false)
    Settings.put(:potion_enabled, true)
    Settings.put(:potion_cooldown_ms, 60_000)
    Settings.put(:potion_battle_clear_ms, 0)

    fresh_battle!(enemies: [%{row: 1, name: "Tentacool"}], locked?: false)
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, low}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    assert_receive {:performed, :high, [{:press, "e"}]}, 1_000
    assert Worker.status(worker).counters.potions >= 1
  end

  # The re-aggro the old any-enemy rule protected against, now caught by what actually
  # interrupts a heal: the player's own HP going DOWN. Window 0 removes the clear-window
  # confound — only the damage guard can hold the sip here.
  @tag :tmp_dir
  test "holds the sip while HP is dropping — a re-aggro with no lock ring", %{
    tmp: tmp,
    body: body
  } do
    Settings.put(:rescue_enabled, false)
    Settings.put(:potion_enabled, true)
    Settings.put(:potion_cooldown_ms, 60_000)
    Settings.put(:potion_battle_clear_ms, 0)

    fresh_battle!(enemies: [%{row: 1, name: "Tentacool"}], locked?: false)

    frames = for fill <- 13..2//-1, do: {:ok, hp_png(tmp, "hp#{fill}.png", fill)}
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: frames})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    refute_receive {:performed, :high, _}, 150
    assert Worker.status(worker).hold_reason =~ "há luta"
  end

  @tag :tmp_dir
  test "after a battle clears for the window, the Pokémon is sent back to its spot", %{
    tmp: tmp,
    body: body
  } do
    Settings.put(:rescue_enabled, false)
    Settings.put(:reposition_enabled, true)
    Settings.put(:reposition_battle_clear_ms, 200)

    {:ok, calib} = Calibration.load()
    Calibration.save(%{calib | pokemon_spot_point: {450, 380}})

    full = hp_png(tmp, "full.png", 20)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, full}]})

    fresh_battle!(enemies: [0])
    worker = start_worker(body)
    assert :ok = Worker.run(worker)
    refute_receive {:performed, _p, _a}, 150
    assert Worker.status(worker).hold_reason == "reposição esperando fim da luta"

    fresh_battle!(enemies: [])
    assert_receive {:performed, :normal, [{:click, :middle, {450, 380}}]}, 1_500
    assert Worker.status(worker).counters.repositions == 1
    assert Worker.status(worker).hold_reason == nil
    assert %{text: "reposição (clique do meio)", at: _} = Worker.status(worker).last_action

    refute_receive {:performed, _p, _a}, 400
  end

  @tag :tmp_dir
  test "flee_to_escape: tile click, walk wait, and arrow steps, all atomic at :critical",
       %{tmp: _tmp, body: body} do
    {:ok, calib} = Calibration.load()
    Calibration.save(%{calib | escape_point: {620, 240}})
    Settings.put(:escape_direction, "left")
    Settings.put(:escape_steps, 2)
    Settings.put(:escape_walk_wait_ms, 1_500)

    worker = start_worker(body)
    assert :ok = Worker.flee_to_escape(worker)

    assert_receive {:performed, :critical, actions}, 1_000

    assert actions == [
             {:click, :left, {620, 240}},
             {:wait, 1_500},
             {:press, "left"},
             {:wait, 300},
             {:press, "left"}
           ]

    assert %{text: "fuga (escada)", at: _} = Worker.status(worker).last_action
  end

  @tag :tmp_dir
  test "flee_to_escape without a calibrated ladder: error and no click", %{tmp: _tmp, body: body} do
    worker = start_worker(body)
    assert {:error, :not_calibrated} = Worker.flee_to_escape(worker)
    refute_receive {:performed, _p, _a}, 150
  end

  @tag :tmp_dir
  test "escape with the game OUT of focus: fronts, reopens the gate, and clicks anyway", %{
    tmp: _tmp,
    body: body
  } do
    alias Pokex.Bots.InputGate

    {:ok, calib} = Calibration.load()
    Calibration.save(%{calib | escape_point: {620, 240}})
    Settings.put(:calibration_front_delay_ms, 1)

    InputGate.set_focus_ok(false)
    on_exit(fn -> InputGate.set_focus_ok(true) end)

    worker = start_worker(body)
    assert :ok = Worker.flee_to_escape(worker)

    assert_receive {:performed, :critical, [{:click, :left, {620, 240}} | _]}, 1_000
    assert InputGate.state().focus_ok
  end

  @tag :tmp_dir
  test "the panic corner vetoes the escape — the human kill switch above all", %{
    tmp: _tmp,
    body: body
  } do
    alias Pokex.Bots.InputGate

    {:ok, calib} = Calibration.load()
    Calibration.save(%{calib | escape_point: {620, 240}})

    InputGate.set_corner_ok(false)
    on_exit(fn -> InputGate.set_corner_ok(true) end)

    worker = start_worker(body)
    assert {:error, :panic_corner} = Worker.flee_to_escape(worker)
    refute_receive {:performed, _p, _a}, 150
  end

  # The calibrated tile is his fishing spot. Walking, sending the Pokémon back to
  # it after every fight would drag him home and undo the whole trip.
  @tag :tmp_dir
  test "in movimento it never repositions, even with the switch on", %{tmp: tmp, body: body} do
    Settings.put(:rescue_enabled, false)
    Settings.put(:reposition_enabled, true)
    Settings.put(:reposition_battle_clear_ms, 50)
    Settings.put(:player_mode, "moving")

    {:ok, calib} = Calibration.load()
    Calibration.save(%{calib | pokemon_spot_point: {450, 380}})

    full = hp_png(tmp, "full.png", 20)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, full}]})

    fresh_battle!(enemies: [0])
    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    fresh_battle!(enemies: [])
    refute_receive {:performed, _p, [{:click, :middle, _} | _]}, 500
    assert Worker.status(worker).counters.repositions == 0
  end

  @tag :tmp_dir
  test "no battle seen → never repositions (nothing to undo)", %{tmp: tmp, body: body} do
    Settings.put(:rescue_enabled, false)
    Settings.put(:reposition_enabled, true)
    Settings.put(:reposition_battle_clear_ms, 50)

    {:ok, calib} = Calibration.load()
    Calibration.save(%{calib | pokemon_spot_point: {450, 380}})

    full = hp_png(tmp, "full.png", 20)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, full}]})

    fresh_battle!(enemies: [])
    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    refute_receive {:performed, _p, _a}, 400
  end

  @tag :tmp_dir
  test "an active fight (lock ring) blocks the potion — the channel would be interrupted", %{
    tmp: tmp,
    body: body
  } do
    Settings.put(:rescue_enabled, false)
    Settings.put(:potion_enabled, true)

    stale_battle!()
    low = hp_png(tmp, "low.png", 6)
    fight = battle_png(tmp, "fight.png", {160, 20, 20, 255})
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, low}, {:ok, fight}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    refute_receive {:performed, _priority, _actions}, 300
    assert Worker.status(worker).counters.potions == 0
  end

  # An unlocked enemy already counts as in-battle for the game, so the heal channel would
  # be interrupted — the old ring-only gate drank here.
  @tag :tmp_dir
  test "enemies in the battle list block the potion even with NO lock ring (aggro before Tab)",
       %{tmp: tmp, body: body} do
    Settings.put(:rescue_enabled, false)
    Settings.put(:potion_enabled, true)

    stale_battle!()
    low = hp_png(tmp, "low.png", 6)
    aggro = battle_png(tmp, "aggro.png", {40, 200, 60, 255})
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, low}, {:ok, aggro}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    refute_receive {:performed, _priority, _actions}, 300
    assert Worker.status(worker).counters.potions == 0
  end

  # Only the HP frame is scripted: a battle capture would consume a warm repeat frame and
  # misread it — the blackboard answer must win.
  @tag :tmp_dir
  test "a FRESH blackboard entry answers the combat question with no battle capture", %{
    tmp: tmp,
    body: body
  } do
    Settings.put(:rescue_enabled, false)
    Settings.put(:potion_enabled, true)

    fresh_battle!(enemies: [0], locked?: true, locked_row: 0)
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, low}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    refute_receive {:performed, _priority, _actions}, 300
    assert Worker.status(worker).counters.potions == 0
  end

  @tag :tmp_dir
  test "use_potion/1 fires immediately on user intent, no gates", %{tmp: tmp, body: body} do
    Settings.put(:potion_enabled, false)
    full = hp_png(tmp, "full.png", 20)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, full}]})

    worker = start_worker(body)
    assert :ok = Worker.use_potion(worker)

    assert_receive {:performed, :high, [{:press, "e"}]}, 500
    assert Worker.status(worker).counters.potions == 1
  end

  @tag :tmp_dir
  test "the toggle off disables the combo entirely", %{tmp: tmp, body: body} do
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, low}]})
    Settings.put(:rescue_enabled, false)

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    refute_receive {:performed, _priority, _actions}, 200
    assert Worker.status(worker).counters.rescues == 0
  end

  # Every one of these was a SILENT hold before: the toggle was on, the HP was
  # low, and the panel said nothing at all — indistinguishable from a broken
  # feature. Measured 2026-07-22 with a probe: HP 32%, potion enabled, zero
  # sips, hold_reason nil.
  describe "when a closed gate holds the support, the panel says which" do
    @tag :tmp_dir
    test "game out of focus: nothing is typed, and the line explains", %{tmp: tmp, body: body} do
      Settings.put(:rescue_enabled, true)
      Settings.put(:potion_enabled, true)
      fresh_battle!(enemies: [])

      Pokex.Bots.InputGate.set_focus_ok(false)
      on_exit(fn -> Pokex.Bots.InputGate.set_focus_ok(true) end)

      low = hp_png(tmp, "low.png", 6)
      {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, low}]})

      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      refute_receive {:performed, _priority, _actions}, 200

      status = Worker.status(worker)
      assert status.counters.rescues == 0
      assert status.hold_reason =~ "fora de foco"
      assert status.hp_pct != nil
    end

    @tag :tmp_dir
    test "a due potion but the reading sees a REAL fight: the line says so", %{
      tmp: tmp,
      body: body
    } do
      Settings.put(:rescue_enabled, false)
      Settings.put(:potion_enabled, true)
      Settings.put(:potion_cooldown_ms, 60_000)

      fresh_battle!(enemies: [%{row: 1, name: "Tentacool"}], locked?: true, locked_row: 1)

      low = hp_png(tmp, "low.png", 6)
      {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, low}]})

      worker = start_worker(body)
      assert :ok = Worker.run(worker)

      refute_receive {:performed, :high, _actions}, 200

      status = Worker.status(worker)
      assert status.counters.potions == 0
      assert status.hp_pct == 32
      assert status.hold_reason =~ "há luta"
    end
  end
end
