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

  @tag :tmp_dir
  test "a MINIMIZED party window (region shows game world) reads UNKNOWN and never acts", %{
    tmp: tmp,
    body: body
  } do
    Settings.put(:rescue_enabled, true)
    Settings.put(:potion_enabled, true)

    # bright, blue-ish "game world" pixels — nothing like the bar's warm fill + black track.
    # The old reader turned this into a garbage low-HP % and fired the combo in a loop.
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

    # halt (what the panic corner calls): even with HP still low, nothing more fires
    assert :ok = Worker.halt(worker)
    assert Worker.status(worker).state == :idle
    reads_at_halt = Worker.status(worker).counters.reads
    refute_receive {:performed, _priority, _actions}, 300
    assert Worker.status(worker).counters.reads == reads_at_halt

    # run re-arms the monitor
    assert :ok = Worker.run(worker)
    assert Worker.status(worker).state == :monitoring
    assert_receive {:performed, :critical, _}, 1_000
  end

  @tag :tmp_dir
  test "the rounded bar tip is corrected: raw 95% reads as a genuinely FULL 100%", %{
    tmp: tmp,
    body: body
  } do
    # 19 of 20 columns filled = raw 95 — exactly what Lucas's real full bar reads, because
    # the bar's rounded tip never paints the last columns of the box.
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
    # Q → move onto the portrait → Shift+Q → Q → recentre
    assert [{:press, "q"} | _] = actions
    assert {:move, {40, 620}} in actions
    assert {:press, "shift+q"} in actions
    assert {:move, {500, 500}} in actions

    assert Worker.status(worker).counters.rescues >= 1
  end

  @tag :tmp_dir
  test "a single low-HP glitch frame between full reads never fires the combo", %{
    tmp: tmp,
    body: body
  } do
    full = hp_png(tmp, "full.png", 20)
    low = hp_png(tmp, "low.png", 6)
    # one garbage low frame sandwiched by full bars — the consecutive-reads guard must hold
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
    # long cooldown so the second, third… ticks are all suppressed
    Settings.put(:rescue_cooldown_ms, 60_000)

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    assert_receive {:performed, :critical, _}, 1_000
    # keeps ticking on the same low HP, but must NOT fire again
    refute_receive {:performed, :critical, _}, 300
    assert Worker.status(worker).counters.rescues == 1
  end

  @tag :tmp_dir
  test "publishes the :pokemon fact — HP when readable, readable?: false when not", %{
    tmp: tmp,
    body: body
  } do
    full = hp_png(tmp, "full.png", 20)
    # bright blue-ish "game world" pixels — the same unrecognizable frame the
    # minimized-window test uses: readable?: false
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

  @tag :tmp_dir
  test "sips a potion when HP is below the potion threshold and no fight is engaged", %{
    tmp: tmp,
    body: body
  } do
    # rescue off so the potion path is what acts; 30% HP < the 70% potion threshold
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

    # blackboard says clear the whole time (fresh entry, no captures of battle needed)
    fresh_battle!(enemies: [])
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, low}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    # one clear read is NOT enough anymore — nothing within the window...
    refute_receive {:performed, :high, _}, 200
    # ...and while the clock runs, the pill says WHY the sip is waiting
    assert Worker.status(worker).hold_reason == "poção esperando batalha limpa"
    # ...but after 300ms of consecutive clear reads, the sip lands
    assert_receive {:performed, :high, [{:press, "e"}]}, 1_000
    assert Worker.status(worker).counters.potions == 1
    assert %{text: "poção", at: _} = Worker.status(worker).last_action
  end

  @tag :tmp_dir
  test "ordem pós-luta: a poção devida espera a captura resolver os corpos", %{
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
    # the catcher is still working a corpse when monitoring starts
    send(worker, {:catcher, %{pending_corpses: 1}})
    assert :ok = Worker.run(worker)

    refute_receive {:performed, :high, _}, 300
    assert Worker.status(worker).hold_reason =~ "esperando a captura terminar"

    # the catcher resolves the corpse → the sip lands right away
    send(worker, {:catcher, %{pending_corpses: 0}})
    assert_receive {:performed, :high, [{:press, "e"}]}, 1_000
  end

  @tag :tmp_dir
  test "o teto solta o suporte se a captura empacar (fail-open)", %{tmp: tmp, body: body} do
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

    # the pending count never clears — past the cap the heal must not starve
    assert_receive {:performed, :high, [{:press, "e"}]}, 2_000
  end

  @tag :tmp_dir
  test "a battle read mid-window RESETS the clear clock", %{tmp: tmp, body: body} do
    Settings.put(:rescue_enabled, false)
    Settings.put(:potion_enabled, true)
    Settings.put(:potion_cooldown_ms, 60_000)
    Settings.put(:potion_battle_clear_ms, 400)

    fresh_battle!(enemies: [])
    low = hp_png(tmp, "low.png", 6)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, low}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    # halfway through the window a fished enemy re-aggresses → the clock must restart
    Process.sleep(200)
    fresh_battle!(enemies: [0])
    Process.sleep(100)
    fresh_battle!(enemies: [])

    # 400ms after the ORIGINAL clear would be now — but the reset means nothing yet
    refute_receive {:performed, :high, _}, 250
    # a full uninterrupted window after the reset → sip
    assert_receive {:performed, :high, [{:press, "e"}]}, 1_000
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

    # a battle is on when monitoring starts...
    fresh_battle!(enemies: [0])
    worker = start_worker(body)
    assert :ok = Worker.run(worker)
    refute_receive {:performed, _p, _a}, 150
    assert Worker.status(worker).hold_reason == "reposição esperando fim da luta"

    # ...the battle ends → after the clear window, ONE middle click on the spot
    fresh_battle!(enemies: [])
    assert_receive {:performed, :normal, [{:click, :middle, {450, 380}}]}, 1_500
    assert Worker.status(worker).counters.repositions == 1
    assert Worker.status(worker).hold_reason == nil
    assert %{text: "reposição (clique do meio)", at: _} = Worker.status(worker).last_action

    # no new battle → no second click
    refute_receive {:performed, _p, _a}, 400
  end

  @tag :tmp_dir
  test "flee_to_escape: clique no tile, espera da caminhada e passos de seta, tudo atômico a :critical",
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
  test "flee_to_escape sem escada calibrada: erro e nenhum clique", %{tmp: _tmp, body: body} do
    worker = start_worker(body)
    assert {:error, :not_calibrated} = Worker.flee_to_escape(worker)
    refute_receive {:performed, _p, _a}, 150
  end

  @tag :tmp_dir
  test "fuga com o jogo FORA de foco: fronta, reabre o gate e clica mesmo assim", %{
    tmp: _tmp,
    body: body
  } do
    alias Pokex.Bots.InputGate

    {:ok, calib} = Calibration.load()
    Calibration.save(%{calib | escape_point: {620, 240}})
    Settings.put(:calibration_front_delay_ms, 1)

    # the panel scenario: browser frontmost → the Focus poller closed the gate
    InputGate.set_focus_ok(false)
    on_exit(fn -> InputGate.set_focus_ok(true) end)

    worker = start_worker(body)
    assert :ok = Worker.flee_to_escape(worker)

    assert_receive {:performed, :critical, [{:click, :left, {620, 240}} | _]}, 1_000
    # the gate reflects the fronted game immediately (the poller would lag)
    assert InputGate.state().focus_ok
  end

  @tag :tmp_dir
  test "o canto de pânico VETA a fuga — kill switch humano acima de tudo", %{
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
  test "em movimento nunca reposiciona, mesmo com a chave ligada", %{tmp: tmp, body: body} do
    Settings.put(:rescue_enabled, false)
    Settings.put(:reposition_enabled, true)
    Settings.put(:reposition_battle_clear_ms, 50)
    Settings.put(:player_mode, "movimento")

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

  @tag :tmp_dir
  test "enemies in the battle list block the potion even with NO lock ring (aggro before Tab)",
       %{tmp: tmp, body: body} do
    Settings.put(:rescue_enabled, false)
    Settings.put(:potion_enabled, true)

    stale_battle!()
    low = hp_png(tmp, "low.png", 6)
    # green HP-bar rows and zero red: an unlocked enemy — the game already counts this as
    # in-battle, so the heal channel would be interrupted. The old ring-only gate drank here.
    aggro = battle_png(tmp, "aggro.png", {40, 200, 60, 255})
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, low}, {:ok, aggro}]})

    worker = start_worker(body)
    assert :ok = Worker.run(worker)

    refute_receive {:performed, _priority, _actions}, 300
    assert Worker.status(worker).counters.potions == 0
  end

  @tag :tmp_dir
  test "a FRESH blackboard entry answers the combat question with no battle capture", %{
    tmp: tmp,
    body: body
  } do
    Settings.put(:rescue_enabled, false)
    Settings.put(:potion_enabled, true)

    fresh_battle!(enemies: [0])
    low = hp_png(tmp, "low.png", 6)
    # ONLY the HP frame is scripted: if the gate tried a battle capture it would consume a
    # repeat of this entry (a warm frame) and misread it — the blackboard answer must win.
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
end
