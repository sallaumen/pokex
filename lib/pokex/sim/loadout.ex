defmodule Pokex.Sim.Loadout do
  @moduledoc """
  What the keys 1-9 DO in the simulated world.

  This module exists because the bench and the playable world disagreed, and
  the disagreement was invisible. `Bench` read his real team and fell back to a
  plain set; the `Runner` was handed `loadout: nil` and built a world whose
  `keys` map was EMPTY. `World.fire/2` looks a key up, finds nothing and returns
  the world unchanged — silently — so in the tab he actually plays, pressing
  1-9 did nothing at all and neither did the engine's own fire order.

  It looked like a hunt where the monsters always won, because it was one.

  One source, used by both, so a bench verdict and a live run can never again be
  answering about two different pokemon.
  """

  alias Pokex.Bots.Combat.Loadout

  @fallback %Loadout{
    name: "Simulado",
    aoe: ["3", "4", "5"],
    single: ["6"],
    buffs: ["2"],
    heal: [],
    crowd: ["1"]
  }

  @doc """
  The loadout of whichever pokemon is on his field, or a plain stand-in.

  Never raises: a simulator that refuses to start because `team.json` is being
  written at that moment would be worse than one running on the fallback, and
  the fallback is named "Simulado" so the screen can say which one it got.
  """
  @spec current() :: Loadout.t()
  def current do
    Loadout.current() || @fallback
  catch
    _kind, _reason -> @fallback
  end

  @doc "The stand-in, for a test that wants a known bar."
  @spec fallback() :: Loadout.t()
  def fallback, do: @fallback
end
