defmodule Pokex.Perception.WorldStateTest do
  # async: false — the ETS table is a named global; tests share it with the app instance.
  use ExUnit.Case, async: false

  alias Pokex.Perception.WorldState

  setup do
    on_exit(fn -> :ets.delete(:pokex_world, :test_key) end)
    :ok
  end

  test "get is :missing before any put" do
    assert WorldState.get(:test_key, 500, 1_000) == :missing
  end

  test "a fresh entry is {:ok, obs}; an old one is {:stale, obs, age}" do
    obs = %{enemies: [0], captured_at: 1_000}
    WorldState.put(:test_key, obs, 1_000)

    assert WorldState.get(:test_key, 500, 1_400) == {:ok, obs}
    assert WorldState.get(:test_key, 500, 1_501) == {:stale, obs, 501}
  end

  test "entries lists what the world knows" do
    WorldState.put(:test_key, %{a: 1}, 42)
    assert {:test_key, %{a: 1}, 42} in WorldState.entries()
  end

  test "forget drops the key back to :missing" do
    WorldState.put(:test_key, %{a: 1}, 42)
    assert :ok = WorldState.forget(:test_key)
    assert WorldState.get(:test_key, 500, 100) == :missing
  end
end
