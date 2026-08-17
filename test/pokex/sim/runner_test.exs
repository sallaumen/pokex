defmodule Pokex.Sim.RunnerTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Cavebot.Route
  alias Pokex.Perception.WorldState
  alias Pokex.Sim.Runner

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

  setup do
    for key <- [:battle, :pokemon, :skill_bar, :minimap, :mini_game], do: WorldState.forget(key)

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

    for key <- [:battle, :pokemon, :skill_bar, :minimap, :mini_game] do
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

  test "the mini game fact says not playing, so the engine keeps deciding", %{server: server} do
    Runner.play(server)
    Runner.tick_now(server)

    assert {:ok, %{playing?: false}} = WorldState.get(:mini_game, 5_000, now())
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
end
