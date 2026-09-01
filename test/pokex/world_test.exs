defmodule Pokex.WorldTest do
  # async: false — the blackboard is global
  use ExUnit.Case, async: false

  alias Pokex.Perception.WorldState
  alias Pokex.World

  setup do
    # one shared blackboard: start from an empty world, never from the last test's
    WorldState.clear()

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
      enemies_detail: [%{row: 0, name: "Pidgeot"}]
    })

    publish(:minimap, %{pos: {337, 46_107, 4}})

    snap = World.snapshot()

    assert snap.me == %{
             pokemon_hp: {5559, 6410},
             hp_pct: nil,
             player_hp: nil,
             level: 90,
             food: 1525,
             fishing: 96
           }

    assert snap.inventory == %{f1: 322, f2: 36, e: 7, s_q: 43}
    assert snap.pos == {337, 46_107, 4}
    assert snap.engaged?
    # a estrela do PXG morreu; o shiny é visto por COR no ShinyGuard
    refute snap.shiny?
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

  test "the health bar the potion logic trusts wins over the digits" do
    # PlayerSupport has read this bar in production for potions and revives all
    # along; a digit the glyph atlas has never seen must not blank the card.
    publish(:pokemon, %{hp_pct: 42, readable?: true})
    publish(:team, %{pokemon_hp: nil, rows: []})

    assert World.pokemon_hp_pct(World.snapshot()) == 0.42
    WorldState.forget(:pokemon)
  end

  test "without that worker the digits still answer" do
    WorldState.forget(:pokemon)
    publish(:team, %{pokemon_hp: {8932, 9215}, rows: []})

    assert_in_delta World.pokemon_hp_pct(World.snapshot()), 8932 / 9215, 0.001
  end

  test "the layout stays true however long ago it was located" do
    # The bug: the layout was read through the 5s perception window, so the
    # panel claimed "HUD não localizado" five seconds after boot, forever. The
    # layout is CONFIGURATION — it stops being true when the panels move, not
    # when the clock advances.
    publish(:layout, %{"regions" => %{}}, 60_000)

    assert World.snapshot().layout?
  end

  test "no layout fact means no layout — never a cheerful default" do
    refute World.snapshot().layout?
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
