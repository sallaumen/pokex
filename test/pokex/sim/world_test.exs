defmodule Pokex.Sim.WorldTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.Cavebot.Route
  alias Pokex.Sim.World

  defp route(waypoints) do
    %Route{
      name: "test",
      waypoints:
        Enum.map(waypoints, fn {x, y, z} ->
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
            gather_ms: nil,
            combo: [],
            skills: [],
            gather_wait_ms: nil
          }
        end)
    }
  end

  defp straight, do: route([{100, 200, 5}, {110, 200, 5}])

  test "starts the character on the first waypoint" do
    world = World.new(straight())

    assert world.pos == {100, 200, 5}
    assert world.clock == 0
  end

  test "holding right increases x" do
    world =
      straight()
      |> World.new(knobs: %{ms_per_tile: 100})
      |> World.press({:key_down, "right"})
      |> World.step(100)

    assert world.pos == {101, 200, 5}
  end

  test "holding down increases y" do
    world =
      straight()
      |> World.new(knobs: %{ms_per_tile: 100})
      |> World.press({:key_down, "down"})
      |> World.step(100)

    assert world.pos == {100, 201, 5}
  end

  test "holding left and up walk the other way" do
    world =
      straight()
      |> World.new(knobs: %{ms_per_tile: 100})
      |> World.press({:key_down, "left"})
      |> World.press({:key_down, "up"})
      |> World.step(100)

    assert world.pos == {99, 199, 5}
  end

  test "two held keys walk both axes at once" do
    world =
      straight()
      |> World.new(knobs: %{ms_per_tile: 100})
      |> World.press({:key_down, "right"})
      |> World.press({:key_down, "down"})
      |> World.step(300)

    assert world.pos == {103, 203, 5}
  end

  test "releasing a key stops that axis" do
    world =
      straight()
      |> World.new(knobs: %{ms_per_tile: 100})
      |> World.press({:key_down, "right"})
      |> World.step(100)
      |> World.press({:key_up, "right"})
      |> World.step(500)

    assert world.pos == {101, 200, 5}
  end

  test "a partial tick carries its remainder instead of rounding it away" do
    world = World.new(straight(), knobs: %{ms_per_tile: 100})
    world = World.press(world, {:key_down, "right"})

    walked = Enum.reduce(1..10, world, fn _tick, w -> World.step(w, 30) end)

    assert walked.pos == {103, 200, 5}
  end

  test "standing still with nothing held does not move" do
    world = straight() |> World.new() |> World.step(5_000)

    assert world.pos == {100, 200, 5}
  end

  test "the clock advances by what was stepped" do
    world = straight() |> World.new() |> World.step(120) |> World.step(80)

    assert world.clock == 200
  end

  test "a thousand ragged ticks walk exactly what the milliseconds owed" do
    world =
      straight()
      |> World.new(knobs: %{ms_per_tile: 320})
      |> World.press({:key_down, "right"})

    walked = Enum.reduce(1..1_000, world, fn _tick, w -> World.step(w, 7) end)

    assert walked.pos == {100 + div(7_000, 320), 200, 5}
  end

  test "holding the same key twice does not double the pace" do
    world =
      straight()
      |> World.new(knobs: %{ms_per_tile: 100})
      |> World.press({:key_down, "right"})
      |> World.press({:key_down, "right"})
      |> World.step(100)

    assert world.pos == {101, 200, 5}
  end

  defp stairway, do: route([{100, 200, 5}, {102, 200, 6}])

  test "derives a stair from a clean pair of waypoints across floors" do
    world = World.new(stairway())

    assert [%{at: {101, 200, 5}, dir: {1, 0}, to_z: 6}] = world.stairs
  end

  test "derives a stair on the vertical axis too" do
    world = World.new(route([{100, 200, 5}, {100, 202, 6}]))

    assert [%{at: {100, 201, 5}, dir: {0, 1}, to_z: 6}] = world.stairs
  end

  test "ignores a dirty cross-floor pair instead of guessing the step" do
    world = World.new(route([{100, 200, 5}, {107, 203, 6}]))

    assert world.stairs == []
  end

  test "reports the cross-floor pairs it refused to turn into stairs" do
    world = World.new(route([{100, 200, 5}, {107, 203, 6}]))

    assert [%{from: {100, 200, 5}, to: {107, 203, 6}}] = world.unsimulated_stairs
  end

  test "a clean pair leaves nothing to report" do
    assert World.new(stairway()).unsimulated_stairs == []
  end

  test "a pair on the same floor is not a stair" do
    world = World.new(route([{100, 200, 5}, {102, 200, 5}]))

    assert world.stairs == []
  end

  test "stepping onto the stair walks two tiles and changes floor" do
    world =
      stairway()
      |> World.new(knobs: %{ms_per_tile: 100})
      |> World.press({:key_down, "right"})
      |> World.step(100)

    assert world.pos == {102, 200, 6}
  end

  test "a stair crossed the other way returns to the floor below" do
    world =
      route([{102, 200, 6}, {100, 200, 5}])
      |> World.new(knobs: %{ms_per_tile: 100})
      |> World.press({:key_down, "left"})
      |> World.step(100)

    assert world.pos == {100, 200, 5}
  end

  test "walking past a stair tile in another direction does not change floor" do
    world =
      stairway()
      |> World.new(knobs: %{ms_per_tile: 100})
      |> World.press({:key_down, "down"})
      |> World.step(300)

    assert world.pos == {100, 203, 5}
  end

  defp nest_route do
    [{100, 200, 5}, {110, 200, 5}]
    |> route()
    |> Map.update!(:waypoints, fn wps ->
      List.update_at(wps, 1, &Map.put(&1, :gather_ms, 2_000))
    end)
  end

  defp lone_mob(extra \\ %{}) do
    World.new(nest_route(),
      knobs:
        Map.merge(
          %{nest_size: 1, nest_radius: 0, aggro_tiles: 99, mob_ms_per_tile: 100, leash_tiles: 99},
          extra
        )
    )
  end

  defp distance({x1, y1, _z1}, {x2, y2, _z2}), do: max(abs(x1 - x2), abs(y1 - y2))

  test "spawns mobs only around waypoints his hand marked" do
    world = World.new(nest_route(), knobs: %{nest_size: 3, nest_radius: 2})

    assert length(world.mobs) == 3

    for mob <- world.mobs do
      {x, y, z} = mob.pos
      assert abs(x - 110) <= 2
      assert abs(y - 200) <= 2
      assert z == 5
    end
  end

  test "spawns nothing on a route with no gather or fight marks" do
    assert World.new(straight()).mobs == []
  end

  test "a fight mark is a nest too" do
    nest =
      [{100, 200, 5}, {110, 200, 5}]
      |> route()
      |> Map.update!(:waypoints, fn wps ->
        List.update_at(wps, 1, &Map.put(&1, :fight_ms, 5_000))
      end)

    assert length(World.new(nest, knobs: %{nest_size: 2}).mobs) == 2
  end

  test "the same seed produces the same world" do
    a = World.new(nest_route(), seed: 7, knobs: %{nest_size: 4, nest_radius: 3})
    b = World.new(nest_route(), seed: 7, knobs: %{nest_size: 4, nest_radius: 3})

    assert Enum.map(a.mobs, & &1.pos) == Enum.map(b.mobs, & &1.pos)
  end

  test "different seeds produce different worlds" do
    a = World.new(nest_route(), seed: 7, knobs: %{nest_size: 4, nest_radius: 3})
    b = World.new(nest_route(), seed: 99, knobs: %{nest_size: 4, nest_radius: 3})

    refute Enum.map(a.mobs, & &1.pos) == Enum.map(b.mobs, & &1.pos)
  end

  test "a mob within aggro range walks toward the character" do
    world = lone_mob()
    [before] = world.mobs
    [after_step] = World.step(world, 100).mobs

    assert distance(after_step.pos, world.pos) < distance(before.pos, world.pos)
  end

  test "a mob outside aggro range stays where it spawned" do
    world = lone_mob(%{aggro_tiles: 2})
    [before] = world.mobs
    [after_step] = World.step(world, 500).mobs

    assert after_step.pos == before.pos
  end

  test "a mob stops next to the character instead of standing on it" do
    world = lone_mob()
    arrived = Enum.reduce(1..40, world, fn _tick, w -> World.step(w, 100) end)
    [mob] = arrived.mobs

    assert distance(mob.pos, arrived.pos) == 1
  end

  test "a mob dragged past its leash vanishes" do
    world = lone_mob(%{leash_tiles: 3})
    assert length(world.mobs) == 1

    dragged = Enum.reduce(1..40, world, fn _tick, w -> World.step(w, 100) end)

    assert dragged.mobs == []
  end

  test "a mob still inside its leash is still there" do
    world = lone_mob(%{leash_tiles: 30})

    kept = Enum.reduce(1..40, world, fn _tick, w -> World.step(w, 100) end)

    assert length(kept.mobs) == 1
  end

  test "a mob on another floor is not walked at all" do
    world = lone_mob()
    [mob] = world.mobs
    upstairs = %{world | mobs: [%{mob | pos: {110, 200, 6}}]}

    [after_step] = World.step(upstairs, 500).mobs

    assert after_step.pos == {110, 200, 6}
  end

  defp loadout do
    %Pokex.Bots.Combat.Loadout{
      name: "Vileplume",
      aoe: ["3", "4"],
      single: ["6"],
      buffs: ["2"],
      heal: [],
      crowd: ["1"]
    }
  end

  defp armed(knobs \\ %{}) do
    World.new(nest_route(),
      loadout: loadout(),
      knobs: Map.merge(%{nest_size: 3, nest_radius: 1, screen_w: 199, screen_h: 199}, knobs)
    )
  end

  test "every skill starts ready" do
    assert World.observe(armed(), :skill_bar) == %{ready_keys: ["1", "2", "3", "4", "6"]}
  end

  test "pressing a skill puts that key on cooldown and leaves the rest ready" do
    world = World.press(armed(), {:press, "3"})
    ready = World.observe(world, :skill_bar).ready_keys

    refute "3" in ready
    assert "4" in ready
  end

  test "a skill comes back after its cooldown" do
    world =
      armed(%{skill_cooldown_ms: 1_000})
      |> World.press({:press, "3"})
      |> World.step(1_000)

    assert "3" in World.observe(world, :skill_bar).ready_keys
  end

  test "a key still on cooldown fires nothing" do
    world = armed(%{skill_cooldown_ms: 9_999, aoe_damage_pct: 10, damage_spread_pct: 0})

    once = World.press(world, {:press, "3"})
    twice = World.press(once, {:press, "3"})

    assert Enum.map(once.mobs, & &1.hp) == Enum.map(twice.mobs, & &1.hp)
  end

  test "an area skill damages every mob in range" do
    hit = World.press(armed(%{aoe_radius: 99}), {:press, "3"})

    assert Enum.all?(hit.mobs, &(&1.hp < 100))
  end

  test "an area skill spares mobs outside its radius" do
    hit = World.press(armed(%{aoe_radius: 0}), {:press, "3"})

    assert Enum.all?(hit.mobs, &(&1.hp == 100))
  end

  test "an area skill kills the mobs it finishes" do
    assert World.press(
             armed(%{aoe_radius: 99, aoe_damage_pct: 100, damage_spread_pct: 0}),
             {:press, "3"}
           ).mobs == []
  end

  test "press_many fires each key it names" do
    world = World.press(armed(), {:press_many, ["3", "4"], []})
    ready = World.observe(world, :skill_bar).ready_keys

    refute "3" in ready
    refute "4" in ready
  end

  test "battle rows are the mobs inside the battle radius" do
    battle = World.observe(armed(%{screen_w: 199, screen_h: 199}), :battle)

    assert battle.enemies == [0, 1, 2]
    assert length(battle.enemies_detail) == 3
  end

  test "a mob outside the battle radius is not on the list" do
    assert World.observe(armed(%{screen_w: 1, screen_h: 1}), :battle).enemies == []
  end

  test "battle detail reports health as a fraction, like the real reader" do
    world =
      armed(%{
        screen_w: 199,
        screen_h: 199,
        aoe_radius: 99,
        aoe_damage_pct: 50,
        damage_spread_pct: 0
      })

    [row | _rest] = World.observe(World.press(world, {:press, "3"}), :battle).enemies_detail

    assert row.hp_pct == 0.5
    assert row.shiny? == false
  end

  test "own_row? puts his pokemon on the list under its own name" do
    battle = World.observe(armed(%{own_row?: true}), :battle)

    assert length(battle.enemies) == 4
    assert Enum.any?(battle.enemies_detail, &(&1.name == "Vileplume"))
  end

  test "own_row? off leaves only enemies on the list" do
    battle = World.observe(armed(%{own_row?: false}), :battle)

    assert length(battle.enemies) == 3
    refute Enum.any?(battle.enemies_detail, &(&1.name == "Vileplume"))
  end

  test "the minimap fact carries the position" do
    world = armed()

    assert World.observe(world, :minimap) == %{pos: world.pos}
  end

  test "the pokemon fact carries readable health" do
    assert World.observe(armed(), :pokemon) == %{hp_pct: 100, readable?: true, fainted?: false}
  end

  test "the pokemon fact carries every key the real publisher writes" do
    real_keys = [:fainted?, :hp_pct, :readable?]

    for world <- [armed(), armed(%{readable?: false})] do
      assert world |> World.observe(:pokemon) |> Map.keys() |> Enum.sort() == real_keys
    end
  end

  test "the mini game fact is published as not playing" do
    assert World.observe(armed(), :mini_game) == %{playing?: false, confidence: 0.0}
  end

  test "an unreadable screen answers nil enemies rather than zero" do
    world = armed(%{readable?: false})
    battle = World.observe(world, :battle)

    assert battle.enemies == nil
    assert battle.enemies_detail == []
    assert World.observe(world, :pokemon) == %{hp_pct: nil, readable?: false, fainted?: false}
  end

  test "an adjacent mob bites the pokemon" do
    world =
      armed(%{
        nest_size: 1,
        nest_radius: 0,
        aggro_tiles: 99,
        mob_ms_per_tile: 50,
        leash_tiles: 99,
        bite_dmg: 5,
        bite_every_ms: 100
      })

    bitten = Enum.reduce(1..20, world, fn _tick, w -> World.step(w, 50) end)

    assert bitten.own.hp_pct < 100
  end

  test "a mob too far away does not bite" do
    world =
      armed(%{nest_size: 1, nest_radius: 0, aggro_tiles: 0, bite_dmg: 5, bite_every_ms: 100})

    assert Enum.reduce(1..20, world, fn _t, w -> World.step(w, 50) end).own.hp_pct == 100
  end

  test "the pokemon falls when its health runs out" do
    world =
      armed(%{
        nest_size: 1,
        nest_radius: 0,
        aggro_tiles: 99,
        mob_ms_per_tile: 50,
        leash_tiles: 99,
        bite_dmg: 20,
        bite_every_ms: 100
      })

    fallen = Enum.reduce(1..60, world, fn _tick, w -> World.step(w, 50) end)

    refute fallen.own.alive?
    refute fallen.own.out?
    assert World.observe(fallen, :pokemon) == %{hp_pct: nil, readable?: false, fainted?: true}
  end

  test "the battle fact it publishes is one the real Situation can count" do
    world = armed(%{screen_w: 199, screen_h: 199})

    picture =
      Pokex.Bots.Engine.Situation.build(
        %{
          battle: World.observe(world, :battle),
          own_hp: World.observe(world, :pokemon).hp_pct,
          own_out?: true,
          own_name: "Vileplume",
          ready_keys: World.observe(world, :skill_bar).ready_keys,
          damage_keys: ["3", "4", "6"]
        },
        %{engage_from: 3},
        1_000
      )

    assert picture.enemies == 3
    assert picture.worth_fighting?
    refute picture.blind?
    assert picture.own_row_seen? == false
  end

  test "own_row? on is discounted by the real Situation instead of inflating the count" do
    world = armed(%{screen_w: 199, screen_h: 199, own_row?: true})

    picture =
      Pokex.Bots.Engine.Situation.build(
        %{
          battle: World.observe(world, :battle),
          own_hp: 100,
          own_out?: true,
          own_name: "Vileplume",
          ready_keys: [],
          damage_keys: []
        },
        %{engage_from: 3},
        1_000
      )

    assert picture.rows == 4
    assert picture.enemies == 3
    assert picture.own_row_seen?
  end

  test "an unreadable screen makes the real Situation say blind, not empty" do
    world = armed(%{readable?: false})

    picture =
      Pokex.Bots.Engine.Situation.build(
        %{
          battle: nil,
          own_hp: nil,
          own_out?: true,
          own_name: "Vileplume",
          ready_keys: nil,
          damage_keys: []
        },
        %{engage_from: 3},
        1_000
      )

    assert World.observe(world, :battle).enemies == nil
    assert picture.enemies == nil
    assert picture.blind?
    refute picture.worth_fighting?
  end

  test "going blind answers nil enemies, never an empty list" do
    world = World.fail(armed(), :blind)

    assert World.observe(world, :battle).enemies == nil
    assert World.observe(world, :pokemon) == %{hp_pct: nil, readable?: false, fainted?: false}
  end

  test "recovering from blindness reads the screen again" do
    world = armed() |> World.fail(:blind) |> World.recover(:blind)

    assert World.observe(world, :battle).enemies == [0, 1, 2]
  end

  test "a dead key spends its cooldown without hurting anything" do
    world =
      armed(%{aoe_radius: 99, aoe_damage_pct: 50, damage_spread_pct: 0})
      |> World.fail({:dead_key, "3"})

    fired = World.press(world, {:press, "3"})

    refute "3" in World.observe(fired, :skill_bar).ready_keys
    assert Enum.all?(fired.mobs, &(&1.hp == 100))
  end

  test "a dead key leaves the other keys working" do
    world =
      armed(%{aoe_radius: 99, aoe_damage_pct: 50, damage_spread_pct: 0})
      |> World.fail({:dead_key, "3"})

    fired = World.press(world, {:press, "4"})

    assert Enum.all?(fired.mobs, &(&1.hp < 100))
  end

  test "the mini game freezes every fact rather than reporting an empty screen" do
    world = World.fail(armed(), :mini_game)

    assert World.observe(world, :battle).enemies == nil
    assert World.observe(world, :mini_game) == %{playing?: true, confidence: 1.0}
  end

  test "the mini game stops the world from moving" do
    world = lone_mob() |> World.fail(:mini_game)
    [before] = world.mobs

    [after_step] = World.step(world, 5_000).mobs

    assert after_step.pos == before.pos
  end

  test "forcing health puts the band where the scenario needs it" do
    world = World.fail(armed(), {:hp, 25})

    assert world.own.hp_pct == 25
    assert World.observe(world, :pokemon).hp_pct == 25
  end

  test "forcing health to zero drops the pokemon" do
    world = World.fail(armed(), {:hp, 0})

    refute world.own.alive?
    assert World.observe(world, :pokemon).fainted?
  end

  test "the world says out loud what is broken" do
    world = armed() |> World.fail(:blind) |> World.fail({:dead_key, "3"})

    assert :blind in world.failures
    assert {:dead_key, "3"} in world.failures
  end

  test "a fallen pokemon stops being bitten" do
    world =
      armed(%{
        nest_size: 1,
        nest_radius: 0,
        aggro_tiles: 99,
        mob_ms_per_tile: 50,
        leash_tiles: 99,
        bite_dmg: 20,
        bite_every_ms: 100
      })

    fallen = Enum.reduce(1..60, world, fn _tick, w -> World.step(w, 50) end)

    assert fallen.own.hp_pct == 0
  end

  # ---------------------------------------------------------------------------
  # What he corrected on 18/08, after playing it: the world was tidier than the
  # game. Nests were always four, the pokemon had no position at all, and the
  # damage per key was a number nobody had ever measured.
  # ---------------------------------------------------------------------------

  describe "how many monsters a corner holds" do
    test "a pinned nest_size still means exactly that many, so a scenario stays controlled" do
      assert length(World.new(nest_route(), knobs: %{nest_size: 2}).mobs) == 2
      assert length(World.new(nest_route(), knobs: %{nest_size: 5}).mobs) == 5
    end

    test "without a pin, marked corners draw from the distribution instead of one number" do
      sizes =
        for seed <- 1..40 do
          length(World.new(nest_route(), seed: seed, knobs: %{stray_chance_pct: 0}).mobs)
        end

      assert Enum.uniq(sizes) |> length() > 1, "every seed gave #{inspect(Enum.uniq(sizes))}"
      assert Enum.min(sizes) >= 1 and Enum.max(sizes) <= 4
    end

    test "a corner his hand did not mark can still hold a stray" do
      plain = route([{100, 200, 5}, {110, 200, 5}])

      counts =
        for seed <- 1..40,
            do: length(World.new(plain, seed: seed, knobs: %{stray_chance_pct: 100}).mobs)

      assert Enum.min(counts) > 0, "a road of 100% strays produced an empty world"
      assert length(World.new(plain, knobs: %{stray_chance_pct: 0}).mobs) == 0
    end

    test "nobody is born on a tile somebody already occupies" do
      world = World.new(nest_route(), knobs: %{nest_size: 8, nest_radius: 0})
      spots = Enum.map(world.mobs, & &1.pos)

      assert length(spots) == 8
      assert length(Enum.uniq(spots)) == 8
      refute world.pos in spots
      refute world.own.pos in spots
    end
  end

  describe "the kill combo he declares" do
    test "the keys he names as the combo kill in exactly that many presses" do
      world = combo_world(["3", "4", "6"])

      two = world |> World.press({:press, "3"}) |> World.press({:press, "4"})
      assert length(two.mobs) == 1, "two thirds of a combo should not be enough"

      assert World.press(two, {:press, "6"}).mobs == []
    end

    test "the share rounds UP, which is the whole reason three presses land" do
      # 100/3 is 33.333: three presses of a rounded-DOWN 33 leave the monster at
      # 1hp, and three presses of the float leave it at a ten-billionth. Both
      # look like the combo failing. This file has already lost tiles to that
      # float and will not lose kills to it.
      assert World.press(combo_world(["3", "4", "6"]), {:press, "3"}).mobs
             |> hd()
             |> Map.fetch!(:hp) == 66
    end

    test "a key outside the combo falls back to the number I invented" do
      world = combo_world(["3"], %{aoe_damage_pct: 10, damage_spread_pct: 0})

      assert World.press(world, {:press, "4"}).mobs |> hd() |> Map.fetch!(:hp) == 90
      assert World.press(world, {:press, "3"}).mobs == []
    end
  end

  describe "the pokemon is a body of its own" do
    test "it starts beside him and not on top of him" do
      world = armed()

      refute world.own.pos == world.pos
      assert distance(world.own.pos, world.pos) == 1
    end

    test "a long walk stretches the gap, and leaving the screen snaps it back" do
      world = armed(%{nest_size: 0, stray_chance_pct: 0})
      held = World.press(world, {:key_down, "right"})

      gaps =
        Enum.map_reduce(1..600, held, fn _tick, w ->
          stepped = World.step(w, 50)
          {distance(stepped.own.pos, stepped.pos), stepped}
        end)
        |> elem(0)

      assert Enum.max(gaps) > world.knobs.pet_follow_tiles,
             "a slower pokemon must fall behind on a long march"

      assert Enum.max(gaps) <= world.knobs.screen_tiles,
             "it must never be left further away than his screen reaches"
    end

    test "a staircase leaves it a floor behind, and the snap brings it up" do
      world =
        World.new(stairway(), loadout: loadout(), knobs: %{nest_size: 0, stray_chance_pct: 0})

      walking = World.press(world, {:key_down, "right"})
      climbed = Enum.reduce(1..40, walking, fn _tick, w -> World.step(w, 50) end)

      assert elem(climbed.pos, 2) == 6
      assert elem(climbed.own.pos, 2) == 6, "the pokemon cannot be left on the old floor"
    end

    test "the revive brings it back at HIS side, not where it fell" do
      world = armed(%{nest_size: 0, stray_chance_pct: 0})

      fallen = %{
        world
        | own: %{world.own | hp_pct: 0, out?: false, alive?: false, pos: {1, 1, 5}}
      }

      back = World.revive(fallen)

      assert back.own.out?
      assert back.own.hp_pct == 100
      assert distance(back.own.pos, back.pos) == 1
    end
  end

  describe "who takes the hit" do
    test "the area is measured from the pokemon, not from him" do
      # One mob far from the pokemon but inside a radius drawn around HIM: it
      # must survive, because the bar belongs to the pokemon and so does the blast.
      world = combo_world(["3"], %{aoe_radius: 2})
      world = %{world | mobs: [%{hd(world.mobs) | pos: shifted(world.pos, 2)}]}

      assert World.press(world, {:press, "3"}).mobs != [],
             "a mob two tiles from HIM but four from the pokemon must not be hit"
    end

    test "he cannot be touched while the pokemon is on the field" do
      world = biting_world()
      chewed = Enum.reduce(1..40, world, fn _tick, w -> World.step(w, 50) end)

      assert chewed.own.hp_pct < 100, "the pokemon should be the one taking it"
      assert chewed.player.hp_pct == 100, "he is invulnerable while it is out"
      assert chewed.player.alive?
    end

    test "once the pokemon falls, the bites land on him instead" do
      world = biting_world()
      long = Enum.reduce(1..400, world, fn _tick, w -> World.step(w, 50) end)

      refute long.own.out?
      assert long.player.hp_pct < 100, "a slow revive has to cost him something"
    end

    test "a fallen pokemon casts nothing" do
      world = combo_world(["3"])
      fallen = %{world | own: %{world.own | hp_pct: 0, out?: false, alive?: false}}

      assert World.press(fallen, {:press, "3"}).mobs == fallen.mobs
    end
  end

  describe "tiles are exclusive" do
    test "a monster walks AROUND him instead of parking behind him" do
      # Straight down the y line, his square sits between the mob and the
      # pokemon. Before the sidestep the mob stopped there and never bit again.
      world = biting_world()
      chased = Enum.reduce(1..80, world, fn _tick, w -> World.step(w, 50) end)

      assert distance(hd(chased.mobs).pos, chased.own.pos) <= 1
    end

    test "no two creatures share a square after a chase" do
      # `bite_dmg: 0` on purpose: this test is about MOVEMENT, and a pokemon
      # that falls mid-chase stops occupying its square (it is back in the ball,
      # and mobs walking over the spot where it fell is correct). Letting it die
      # here would turn a movement invariant into a health one.
      world =
        armed(%{nest_size: 6, nest_radius: 1, aggro_tiles: 99, mob_ms_per_tile: 50, bite_dmg: 0})

      settled = Enum.reduce(1..200, world, fn _tick, w -> World.step(w, 50) end)
      spots = Enum.map(settled.mobs, & &1.pos)

      assert length(Enum.uniq(spots)) == length(spots)
      refute settled.pos in spots
      refute settled.own.pos in spots
    end
  end

  defp combo_world(combo, extra \\ %{}) do
    {seed, extra} = Map.pop(extra, :seed, 42)

    knobs =
      Map.merge(
        %{
          kill_combo: combo,
          damage_spread_pct: 0,
          nest_size: 1,
          nest_radius: 0,
          aggro_tiles: 0,
          aoe_radius: 4,
          stray_chance_pct: 0
        },
        extra
      )

    world = World.new(nest_route(), loadout: loadout(), knobs: knobs, seed: seed)
    {x, y, z} = world.own.pos

    %{world | mobs: [%{hd(world.mobs) | pos: {x, y + 1, z}}]}
  end

  defp biting_world do
    World.new(nest_route(),
      loadout: loadout(),
      knobs: %{
        nest_size: 1,
        nest_radius: 0,
        aggro_tiles: 99,
        mob_ms_per_tile: 50,
        leash_tiles: 99,
        bite_dmg: 2,
        bite_every_ms: 100,
        player_bite_dmg: 5,
        stray_chance_pct: 0
      }
    )
  end

  defp shifted({x, y, z}, by), do: {x + by, y, z}

  describe "the engine only ever sees the screen" do
    test "the window is a RECTANGLE: seven tiles across, five up" do
      # Measured on his real Meganium route before this fix: a Chebyshev radius
      # of 7 handed the engine 32 of 346 sightings that no screen ever showed —
      # 9.2%. He asked for exactly this guarantee, and it was not being kept.
      # NOT `armed/1`: that helper opens the window to 199x199 so other tests
      # can see everything. This one has to run on the real default.
      world = World.new(nest_route(), knobs: %{nest_size: 0, stray_chance_pct: 0})
      assert {world.knobs.screen_w, world.knobs.screen_h} == {15, 11}
      {x, y, z} = world.pos

      at = fn dx, dy ->
        seen = %{world | mobs: [mob_at({x + dx, y + dy, z})]}
        World.observe(seen, :battle).enemies != []
      end

      assert at.(7, 0), "seven across is the last column the game draws"
      refute at.(8, 0), "eight across is off the side of the window"
      assert at.(0, 5), "five up is the last row the game draws"
      refute at.(0, 6), "six up is off the top — this is what used to leak"
      refute at.(0, 7), "and seven up was leaking too"
    end

    test "another floor is never on screen, however close" do
      world = World.new(nest_route(), knobs: %{nest_size: 0, stray_chance_pct: 0})
      {x, y, z} = world.pos
      upstairs = %{world | mobs: [mob_at({x, y, z + 1})]}

      assert World.observe(upstairs, :battle).enemies == []
    end

    test "the window is his to set, because I did not measure it" do
      world =
        World.new(nest_route(),
          knobs: %{nest_size: 0, stray_chance_pct: 0, screen_w: 3, screen_h: 3}
        )

      {x, y, z} = world.pos

      assert World.observe(%{world | mobs: [mob_at({x + 1, y, z})]}, :battle).enemies != []
      assert World.observe(%{world | mobs: [mob_at({x + 2, y, z})]}, :battle).enemies == []
    end
  end

  describe "damage is a band, not a number" do
    test "the enemy's health is his to calibrate" do
      assert hd(World.new(nest_route(), knobs: %{nest_size: 1, mob_hp: 480}).mobs).max_hp == 480
    end

    test "the same key does not land the same number twice" do
      rolls =
        for seed <- 1..30 do
          w = combo_world([], %{aoe_damage_pct: 50, damage_spread_pct: 40, seed: seed})
          World.press(w, {:press, "3"}).mobs |> hd() |> Map.fetch!(:hp)
        end

      assert length(Enum.uniq(rolls)) > 1, "a fixed number is exactly what he asked me to remove"
      assert Enum.min(rolls) >= 100 - 70 and Enum.max(rolls) <= 100 - 30
    end

    test "a spread of zero gives back the old certainty, for anyone who wants it" do
      rolls =
        for seed <- 1..10 do
          w = combo_world([], %{aoe_damage_pct: 50, damage_spread_pct: 0, seed: seed})
          World.press(w, {:press, "3"}).mobs |> hd() |> Map.fetch!(:hp)
        end

      assert Enum.uniq(rolls) == [50]
    end

    test "his own range for a key beats both the combo and my invented number" do
      world = combo_world(["3"], %{skill_damage: %{"3" => {7, 7}}})

      assert World.press(world, {:press, "3"}).mobs |> hd() |> Map.fetch!(:hp) == 93
    end

    test "a volley kills some and leaves a survivor on a sliver" do
      # THE situation he wants to watch the engine handle: the area skill does
      # not finish everyone, and someone has to go and finish the last one.
      world =
        World.new(nest_route(),
          loadout: loadout(),
          knobs: %{
            nest_size: 8,
            nest_radius: 2,
            aoe_radius: 99,
            aoe_damage_pct: 100,
            damage_spread_pct: 30,
            stray_chance_pct: 0
          }
        )

      after_volley = World.press(world, {:press, "3"})

      assert after_volley.stats.killed > 0, "a full-strength volley has to kill somebody"
      assert after_volley.mobs != [], "and its lower rolls have to leave somebody standing"
      assert Enum.all?(after_volley.mobs, &(&1.hp < &1.max_hp))
    end
  end

  defp mob_at(pos) do
    %{
      id: 99,
      name: "Venonat",
      pos: pos,
      hp: 100,
      max_hp: 100,
      spawn: pos,
      walk_debt_ms: 0,
      bite_debt_ms: 0
    }
  end
end
