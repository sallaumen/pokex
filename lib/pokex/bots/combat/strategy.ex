defmodule Pokex.Bots.Combat.Strategy do
  @moduledoc """
  Which keys the fight presses, and in what order — decided from what the keys
  DO, not from a hand-written list.

  The bot used to press `skill_keys`, one global priority list that knows
  nothing about the pokémon holding the bar or about how many things are on
  screen. Two consequences he named on 2026-08-11: a swap makes the list wrong,
  and "quando você fica tentando matar de um em um, ele é extremamente mais
  lento" cannot be avoided by a list that cannot tell area from single-target.

  So the order is computed, per burst, from three things:

    * the **loadout** — this pokémon's keys by job (`Pokex.Bots.Combat.Loadout`)
    * **how many enemies** are on the battle list right now
    * whether this is the **opening** of a gathered pile

  The rules, in his words:

    * opening after a gathering → **area first**, always. The pile only exists
      because the hunt spent a whole stretch building it.
    * a crowd (`aoe_from` or more) → area first: the same reason, without the
      gathering.
    * one or two → **single-target first**. "se fossemos inteligentes,
      poderíamos contar a quantidade de inimigos, e ir usando as skills single
      target primeiro com poucos inimigos e guardar para mobar em inimigos
      maiores".
    * **control never**. It is the stun the auto-revive borrows; spending it
      here is why it is not there when the recall needs it.
    * **aura and heal never** either — not because they are useless, but
      because they answer to moments this function does not own (the middle of
      the huddle, and a health bar). A rotation that presses them "sometime" is
      exactly the mistake of gluing separate moments into one sequence.

  Nothing here reads the world or the clock: given the same three inputs it
  always answers the same order, which is what makes the rules arguable.
  """

  alias Pokex.Bots.Combat.Loadout

  @type opts :: [enemies: non_neg_integer, opening?: boolean, aoe_from: pos_integer]

  @doc """
  The keys to press, best first — `[]` when this pokémon has nothing to attack
  with, which the caller must read as "fall back to the configured list".

  `:enemies` defaults to 1 (the pessimistic read: a lone target is the case
  where firing area first wastes the most).
  """
  @spec skill_order(Loadout.t() | nil, opts) :: [String.t()]
  def skill_order(nil, _opts), do: []

  def skill_order(%Loadout{} = loadout, opts) do
    if area_first?(loadout, opts),
      do: loadout.aoe ++ loadout.single,
      else: loadout.single ++ loadout.aoe
  end

  @doc """
  The opening burst for a pile that has just finished gathering: the area keys,
  then the single-target ones.

  This is what replaces the raw recorded combo once the pokémon's keys are
  classified — the recorded one presses whatever his hands pressed at that
  waypoint, which stops being true the moment he swaps pokémon, and can even
  spend a control skill that was supposed to survive for the revive.
  """
  @spec opening(Loadout.t() | nil) :: [String.t()]
  def opening(loadout), do: skill_order(loadout, opening?: true)

  @doc """
  The keys that must never be pressed by an ordinary fight, whatever the
  situation: this pokémon's control skills.

  Exposed so the caller can PROVE the exclusion rather than trust it.
  """
  @spec reserved(Loadout.t() | nil) :: [String.t()]
  def reserved(nil), do: []
  def reserved(%Loadout{} = loadout), do: loadout.crowd

  # A gathered pile is a crowd by definition — its size is the whole point of
  # having gathered it, and the battle list at that instant may still be
  # catching up with what is walking in.
  defp area_first?(_loadout, opts) do
    if Keyword.get(opts, :opening?, false) do
      true
    else
      Keyword.get(opts, :enemies, 1) >= Keyword.get(opts, :aoe_from, 3)
    end
  end
end
