defmodule Pokex.SettingsStash do
  @moduledoc """
  Stash + restore GLOBAL settings around a test.

  Replaces the originals-map + on_exit block hand-rolled (and drifting) across
  worker tests. Global settings are shared mutable state — every test that
  writes them MUST restore them, or later tests inherit the leak (the known
  source of the suite's order-dependent flakiness).

      setup do
        SettingsStash.stash!(mini_game_tick_ms: 20, mini_game_enter_streak: 1)
        # keys the TEST BODY may put later, so they restore too:
        SettingsStash.stash_keys!([:mini_game_anchor_tolerance])
      end
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Pokex.Settings

  @doc """
  Snapshot each key, register restore on exit, then apply the overrides.

  A REFUSED put RAISES. `Settings.put/3` answers `{:error, reason}` for a value
  outside the key's range, and swallowing that let a test ask for 300ms on a key
  with a 500ms floor and then assert against the untouched 3000 — green, while
  proving the opposite of what it claimed (2026-08-10). A test that cannot get
  the world it asked for has to fail HERE, not silently somewhere else.
  """
  def stash!(overrides) do
    overrides |> Enum.map(fn {key, _value} -> key end) |> stash_keys!()

    Enum.each(overrides, fn {key, value} ->
      case Settings.put(key, value) do
        {:error, reason} -> raise ArgumentError, "stash! recusado — #{reason}"
        _applied -> :ok
      end
    end)

    :ok
  end

  @doc "Snapshot keys and register restore on exit — for puts done mid-test."
  def stash_keys!(keys) do
    originals = Map.new(keys, &{&1, Settings.get(&1)})
    on_exit(fn -> Enum.each(originals, fn {key, value} -> Settings.put(key, value) end) end)
    :ok
  end
end
