defmodule Pokex.PerceptionTest do
  # async: false — reads the named global WorldState table.
  use ExUnit.Case, async: false

  alias Pokex.Perception
  alias Pokex.Perception.WorldState

  setup do
    on_exit(fn -> WorldState.forget(:mini_game) end)
    :ok
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
end
