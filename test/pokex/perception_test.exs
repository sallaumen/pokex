defmodule Pokex.PerceptionTest do
  # async: false — reads the named global WorldState table.
  use ExUnit.Case, async: false

  alias Pokex.Perception
  alias Pokex.Perception.WorldState

  setup do
    # one shared blackboard: start from an empty world, never from the last test's
    WorldState.clear()

    on_exit(fn ->
      WorldState.forget(:mini_game)
      WorldState.forget(:minimap)
      WorldState.forget(:pokemon)
      WorldState.forget(:skill_bar)
    end)

    :ok
  end

  test "pokemon mirrors a fresh fact and fails open on stale/missing" do
    refute match?({:ok, _}, Perception.pokemon(10_000))

    WorldState.put(:pokemon, %{hp_pct: 62, readable?: true}, 10_000)
    assert Perception.pokemon(10_100) == {:ok, %{hp_pct: 62, readable?: true}}

    stale_at = 10_000 + Pokex.Settings.get(:pokemon_fact_max_age_ms) + 1
    assert Perception.pokemon(stale_at) == :unknown
  end

  test "minimap returns the fresh position and is :unknown when missing, nil or stale" do
    assert Perception.minimap(10_000) == :unknown

    WorldState.put(:minimap, %{pos: {337, 46_107, 4}}, 10_000)
    assert Perception.minimap(10_100) == {:ok, %{pos: {337, 46_107, 4}}}

    WorldState.put(:minimap, %{pos: nil}, 10_200)
    assert Perception.minimap(10_300) == :unknown

    WorldState.put(:minimap, %{pos: {337, 46_107, 4}}, 10_000)
    stale_at = 10_000 + Pokex.Settings.get(:cavebot_minimap_fact_max_age_ms) + 1
    assert Perception.minimap(stale_at) == :unknown
  end

  test "mini_game_playing? mirrors a fresh fact" do
    WorldState.put(:mini_game, %{playing?: true, confidence: 0.9}, 10_000)
    assert Perception.mini_game_playing?(10_100)

    WorldState.put(:mini_game, %{playing?: false, confidence: 0.1}, 10_000)
    refute Perception.mini_game_playing?(10_100)
  end

  test "mini_game_playing? fails open on a missing fact" do
    refute Perception.mini_game_playing?(10_000)
  end

  test "mini_game_playing? fails open on a stale fact — a dead worker never strands peers" do
    WorldState.put(:mini_game, %{playing?: true, confidence: 0.9}, 10_000)
    stale_at = 10_000 + Pokex.Settings.get(:mini_game_fact_max_age_ms) + 1

    refute Perception.mini_game_playing?(stale_at)
  end

  # unknown is nil, never []: an empty list would read "all on cooldown" and stall
  # combat, while nil lets it blind-rotate
  test "ready_skills mirrors a fresh :skill_bar fact and is UNKNOWN on stale/missing" do
    assert Perception.ready_skills(10_000) == nil

    WorldState.put(:skill_bar, %{states: [:ready, :cooldown], ready_keys: ["1"]}, 10_000)
    assert Perception.ready_skills(10_100) == ["1"]

    WorldState.put(:skill_bar, %{states: nil, ready_keys: nil}, 10_200)
    assert Perception.ready_skills(10_300) == nil

    WorldState.put(:skill_bar, %{states: [:ready], ready_keys: ["1"]}, 10_000)
    stale_at = 10_000 + Pokex.Settings.get(:skill_bar_fact_max_age_ms) + 1
    assert Perception.ready_skills(stale_at) == nil
  end
end
