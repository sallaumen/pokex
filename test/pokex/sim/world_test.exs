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
end
