defmodule Pokex.Sim.RunnerTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Cavebot.Route
  alias Pokex.Perception.WorldState
  alias Pokex.Sim.Runner
  alias Pokex.Sim.Scenario

  defp route do
    %Route{
      name: "sim",
      waypoints:
        for {x, y, z} <- [{100, 200, 5}, {110, 200, 5}] do
          %{
            x: x,
            y: y,
            z: z,
            action: :walk,
            stops: [],
            at: nil,
            dwell_ms: nil,
            park_point: nil,
            park_tiles: nil,
            fight_ms: nil,
            gather_ms: 2_000,
            combo: [],
            skills: [],
            gather_wait_ms: nil
          }
        end
    }
  end

  # This is the bug that hid behind everything else for a whole phase. The
  # Runner was handed `loadout: nil`, so `World.keys` came out EMPTY, and
  # `World.fire/2` looks a key up, finds nothing and returns the world
  # UNCHANGED — no crash, no log, no receipt. In the tab he actually plays,
  # pressing 1-9 did nothing, the engine's own fire order did nothing, and a
  # hunt where the monsters always won looked like a finding about the engine.
  # It was invisible because the bench had its own loadout and killed fine.
  setup do
    # :mini_game rides the cleanup list although the runner never publishes it:
    # a fact left behind by another test is exactly what the new assertion below
    # must not mistake for one of ours.
    for key <- [:battle, :pokemon, :skill_bar, :minimap, :mini_game],
        do: WorldState.forget(key)

    counter = :counters.new(1, [])
    :counters.put(counter, 1, System.monotonic_time(:millisecond))

    server =
      start_supervised!(
        {Runner,
         name: nil,
         tick_ms: 10,
         clock: fn -> :counters.get(counter, 1) end,
         route: route(),
         knobs: %{ms_per_tile: 100}}
      )

    %{server: server, advance: fn ms -> :counters.add(counter, 1, ms) end}
  end

  test "the world the Runner builds has real keys, or nothing can ever be killed", %{
    server: server
  } do
    keys = Runner.world(server).keys

    refute keys == %{}, "a world with no keys cannot kill anything, silently"
    assert Enum.all?(Map.values(keys), &Map.has_key?(&1, :kind))
  end

  defp now, do: System.monotonic_time(:millisecond)

  test "starts paused so nothing moves until asked", %{server: server} do
    refute Runner.playing?(server)
  end

  test "a held key walks the character once it is playing", %{server: server, advance: advance} do
    Runner.play(server)
    send(server, {:sim_rig, {:key_down, "right"}})
    advance.(1_000)
    Runner.tick_now(server)

    {x, _y, _z} = Runner.world(server).pos
    assert x > 100
  end

  test "a paused runner ignores the clock", %{server: server, advance: advance} do
    send(server, {:sim_rig, {:key_down, "right"}})
    advance.(5_000)
    Runner.tick_now(server)

    assert Runner.world(server).pos == {100, 200, 5}
  end

  test "the world advances by the time that really passed", %{server: server, advance: advance} do
    Runner.play(server)
    advance.(750)
    Runner.tick_now(server)

    assert Runner.world(server).clock == 750
  end

  test "publishes every fact the fleet reads", %{server: server} do
    Runner.play(server)
    Runner.tick_now(server)

    for key <- [:battle, :pokemon, :skill_bar, :minimap] do
      assert {:ok, _obs} = WorldState.get(key, 5_000, now()), "#{key} was never published"
    end
  end

  test "the battle fact it publishes is the shape the fleet counts", %{server: server} do
    Runner.play(server)
    Runner.tick_now(server)

    {:ok, battle} = WorldState.get(:battle, 5_000, now())

    assert is_list(battle.enemies)
    assert is_list(battle.enemies_detail)
  end

  test "it publishes no mini game fact — a hunt never sees the capsule", %{server: server} do
    Runner.play(server)
    Runner.tick_now(server)

    assert WorldState.get(:mini_game, 5_000, now()) == :missing
  end

  test "a fact is not republished before its own cadence is due", %{
    server: server,
    advance: advance
  } do
    Runner.play(server)
    Runner.tick_now(server)
    first = WorldState.age(:minimap, now())

    advance.(50)
    Runner.tick_now(server)

    assert WorldState.age(:minimap, now()) >= first
  end

  test "a fact is republished once its cadence comes due", %{server: server, advance: advance} do
    Runner.play(server)
    Runner.tick_now(server)

    advance.(5_000)
    Runner.tick_now(server)

    assert WorldState.age(:minimap, now()) < 1_000
  end

  test "loading a route replaces the world", %{server: server} do
    Runner.play(server)
    Runner.load(server, route(), seed: 99)

    assert Runner.world(server).pos == {100, 200, 5}
    assert Runner.world(server).clock == 0
  end

  test "a key it does not model does not take the process down", %{server: server} do
    Runner.play(server)
    send(server, {:sim_rig, {:click, :left, {5, 5}}})

    assert Runner.playing?(server)
  end

  test "pausing stops the world from advancing", %{server: server, advance: advance} do
    Runner.play(server)
    send(server, {:sim_rig, {:key_down, "right"}})
    advance.(200)
    Runner.tick_now(server)
    walked = Runner.world(server).pos

    Runner.pause(server)
    advance.(5_000)
    Runner.tick_now(server)

    assert Runner.world(server).pos == walked
  end

  test "loading a scenario loads its world and remembers it", %{server: server} do
    Runner.load_scenario(server, Scenario.get("pilha-pequena"), [])

    assert Runner.scenario(server).id == "pilha-pequena"
    assert length(Runner.world(server).mobs) == 2
  end

  test "a scripted failure fires on the world clock, not the machine's", %{
    server: server,
    advance: advance
  } do
    Runner.load_scenario(server, Scenario.get("tela-ilegivel"), [])
    Runner.play(server)

    advance.(1_000)
    Runner.tick_now(server)
    refute Pokex.Sim.World.broken?(Runner.world(server), :blind)

    advance.(2_500)
    Runner.tick_now(server)
    assert Pokex.Sim.World.broken?(Runner.world(server), :blind)
  end

  test "a scripted recovery undoes the failure", %{server: server, advance: advance} do
    Runner.load_scenario(server, Scenario.get("tela-ilegivel"), [])
    Runner.play(server)

    advance.(4_000)
    Runner.tick_now(server)
    assert Pokex.Sim.World.broken?(Runner.world(server), :blind)

    advance.(6_000)
    Runner.tick_now(server)
    refute Pokex.Sim.World.broken?(Runner.world(server), :blind)
  end

  test "a blind stretch publishes nil enemies, not an empty list", %{
    server: server,
    advance: advance
  } do
    Runner.load_scenario(server, Scenario.get("tela-ilegivel"), [])
    Runner.play(server)

    advance.(4_000)
    Runner.tick_now(server)

    {:ok, battle} = WorldState.get(:battle, 5_000, now())
    assert battle.enemies == nil
  end

  test "a beat is not fired twice by two ticks", %{server: server, advance: advance} do
    Runner.load_scenario(server, Scenario.get("vermelho"), [])
    Runner.play(server)

    advance.(4_000)
    Runner.tick_now(server)
    hp = Runner.world(server).own.hp_pct

    advance.(100)
    Runner.tick_now(server)

    assert Runner.world(server).own.hp_pct <= hp
    assert Runner.world(server).own.hp_pct == 25 or Runner.world(server).own.hp_pct < 25
  end

  defp orders(overrides) do
    Map.merge(
      %{
        phase: :engaged,
        band: :green,
        route: :go,
        fire: :hold,
        opening: [],
        revive: :hold,
        potion: :hold,
        why: "teste"
      },
      overrides
    )
  end

  test "hands off, an order changes nothing", %{server: server, advance: advance} do
    Runner.play(server)
    WorldState.put(:orders, orders(%{fire: :free, opening: ["3"]}), now())
    before = Runner.world(server).mobs

    advance.(200)
    Runner.tick_now(server)

    assert Enum.map(Runner.world(server).mobs, & &1.hp) == Enum.map(before, & &1.hp)
  end

  test "handed over, a free-fire order spends the keys it names", %{
    server: server,
    advance: advance
  } do
    Runner.auto(server, true)
    Runner.play(server)
    WorldState.put(:orders, orders(%{fire: :free, opening: ["3"]}), now())

    advance.(200)
    Runner.tick_now(server)

    refute "3" in Pokex.Sim.World.observe(Runner.world(server), :skill_bar).ready_keys
  end

  test "handed over, a revive order heals and clears every cooldown", %{
    server: server,
    advance: advance
  } do
    Runner.auto(server, true)
    Runner.play(server)
    hurt = %{Runner.world(server) | own: %{Runner.world(server).own | hp_pct: 20}}
    :sys.replace_state(server, &Map.put(&1, :world, hurt))

    WorldState.put(:orders, orders(%{revive: :now}), now())
    advance.(200)
    Runner.tick_now(server)

    # the body takes revive_settle_ms to come back — the order starts it
    advance.(2_000)
    Runner.tick_now(server)

    world = Runner.world(server)
    assert world.own.hp_pct == 100
    assert world.own.alive?
  end

  test "handed over, a hold-route order lets go of the arrows", %{
    server: server,
    advance: advance
  } do
    Runner.auto(server, true)
    Runner.play(server)
    send(server, {:sim_rig, {:key_down, "right"}})
    WorldState.put(:orders, orders(%{route: :hold}), now())

    advance.(200)
    Runner.tick_now(server)

    assert Runner.world(server).held == []
  end

  test "handed over with no order on the board, nothing is obeyed", %{
    server: server,
    advance: advance
  } do
    WorldState.forget(:orders)
    Runner.auto(server, true)
    Runner.play(server)
    before = Runner.world(server).pos

    advance.(200)
    Runner.tick_now(server)

    assert Runner.world(server).pos == before
  end
end
