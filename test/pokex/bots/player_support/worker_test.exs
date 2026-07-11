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
  alias Pokex.{Calibration, Settings}

  @keys [
    :support_tick_ms,
    :rescue_step_ms,
    :rescue_enabled,
    :rescue_cooldown_ms,
    :pokemon_hp_rescue_pct,
    :potion_enabled,
    :potion_cooldown_ms,
    :pokemon_hp_potion_pct
  ]

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    originals = Map.new(@keys, &{&1, Settings.get(&1)})

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      Enum.each(originals, fn {k, v} -> Settings.put(k, v) end)
    end)

    Settings.put(:support_tick_ms, 20)
    Settings.put(:rescue_step_ms, 0)
    # the combo ships OFF by default; the enabled-path tests turn it on ("toggle off" flips it back)
    Settings.put(:rescue_enabled, true)

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
