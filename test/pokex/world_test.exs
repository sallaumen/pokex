defmodule Pokex.WorldTest do
  # async: false — the blackboard is global
  use ExUnit.Case, async: false

  alias Pokex.Perception.WorldState
  alias Pokex.World

  setup do
    on_exit(fn ->
      for key <- [:hud, :team, :battle, :minimap, :layout], do: WorldState.forget(key)
    end)

    :ok
  end

  defp publish(key, obs, age_ms \\ 0) do
    WorldState.put(key, obs, System.monotonic_time(:millisecond) - age_ms)
  end

  test "assembles one coherent view out of every feed's fact" do
    publish(:hud, %{level: 90, food: 1525, fishing: 96, slots: %{f1: 322, f2: 36, e: 7, s_q: 43}})
    publish(:team, %{pokemon_hp: {5559, 6410}, rows: [%{slot: 2, present?: true, hp_pct: 0.86}]})

    publish(:battle, %{
      locked?: true,
      shiny_rows: [1],
      enemies_detail: [%{row: 0, name: "Pidgeot"}]
    })

    publish(:minimap, %{pos: {337, 46107, 4}})

    snap = World.snapshot()

    assert snap.me == %{pokemon_hp: {5559, 6410}, level: 90, food: 1525, fishing: 96}
    assert snap.inventory == %{f1: 322, f2: 36, e: 7, s_q: 43}
    assert snap.pos == {337, 46107, 4}
    assert snap.engaged?
    assert snap.shiny?
    assert [%{name: "Pidgeot"}] = snap.enemies
    assert World.pokemon_hp_pct(snap) == 5559 / 6410
    assert World.team_health(snap) == %{2 => 0.86}
  end

  test "a fact nobody is feeding goes nil instead of lingering as a confident lie" do
    publish(
      :hud,
      %{level: 90, food: 1525, fishing: 96, slots: %{f1: 322, f2: 36, e: 7, s_q: 43}},
      60_000
    )

    snap = World.snapshot()

    assert snap.me.level == nil
    assert snap.inventory == %{f1: nil, f2: nil, e: nil, s_q: nil}
  end

  test "an empty blackboard still answers — holes, never a crash" do
    snap = World.snapshot()

    assert snap.me.level == nil
    assert snap.team == []
    assert snap.enemies == []
    assert snap.pos == nil
    refute snap.engaged?
    refute snap.shiny?
    assert World.pokemon_hp_pct(snap) == nil
  end
end
