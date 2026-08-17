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
end
