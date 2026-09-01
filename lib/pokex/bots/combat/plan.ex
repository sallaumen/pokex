defmodule Pokex.Bots.Combat.Plan do
  @moduledoc """
  WHICH keys a hunt fights with — asked once, answered by the mode.

  Two functions used to compose keys, in two modules, for two callers:
  `Engine.Inputs.hands/4` builds the hand the BRAIN names in its orders, and
  `Combat.Logic.attack_keys/2` builds the rotation the FIGHT sustains. They
  agree today because both call `Combat.Strategy` — and the moment a mode wants
  a different hand, "both call the same module" stops being enough: the mode has
  to reach both, or the brain plans a burst the hand never presses.

  So the mode picks ONE module and every key question goes through it.

  ## The five questions

    * `opening/2` — the burst that opens a fight.
    * `sustained/2` — what keeps firing while the fight lasts. `[]` is a legal
      answer and means "this mode does not press keys one by one".
    * `small/2` and `single/2` — the cheap hands: what a pile the ruler already
      called "not worth the area" gets, and what a skipped pile gets on the way
      past.
    * `crowd/2` — the control keys the BRAIN may spend. `[]` means the mode has
      no control key of its own to spend (the game's own combo ends in one).
    * `damage_keys/2` — what `Situation.spent?` measures. This is the pivot the
      whole revive brain turns on: R3b, the kite, `pile_payable?` and the boss's
      covered revive all ask "is the bar gone?", and the answer is only as true
      as this list. A mode that presses one key and reports six is a mode whose
      revive never fires — silently, which is exactly how the single-target keys
      broke `spent?` on 29/08.
    * `tab?/1` — whether the fight starts by locking a target.

  ## Why the context is a map

  A callback list that grows an argument per rule is a callback list nobody can
  add a rule to. The map carries what the caller happens to know — the count on
  screen, the bar reading, whether this is an opening — and a plan reads the
  fields it needs. Absent is UNKNOWN everywhere, and every implementation has to
  answer for it.
  """

  alias Pokex.Bots.Combat.Loadout
  alias Pokex.Bots.Combat.Plan
  alias Pokex.Bots.HuntMode

  @typedoc """
  What the caller knows: `:enemies` (count on screen, `nil` unknown),
  `:ready_keys` (the bar, `nil` unreadable), `:opening?`, and `:config` — the
  knobs, by whatever name that caller holds them under.
  """
  @type ctx :: map

  @callback opening(Loadout.t() | nil, ctx) :: [String.t()]
  @callback sustained(Loadout.t() | nil, ctx) :: [String.t()]
  @callback small(Loadout.t() | nil, ctx) :: [String.t()]
  @callback single(Loadout.t() | nil, ctx) :: [String.t()]
  @callback crowd(Loadout.t() | nil, ctx) :: [String.t()]
  @callback damage_keys(Loadout.t() | nil, ctx) :: [String.t()]
  @callback tab?(ctx) :: boolean

  @doc """
  The plan `mode` fights with.

  Anything that is not a mode answers `Plan.Standard` — the bot exactly as it
  fought before any of this existed, which is the right answer for a caller who
  could not say what it wanted.
  """
  @spec for(HuntMode.t() | nil) :: module
  def for(:auto_combo), do: Plan.AutoCombo
  def for(_standard_or_unknown), do: Plan.Standard
end
